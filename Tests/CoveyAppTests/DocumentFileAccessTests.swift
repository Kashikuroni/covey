import XCTest
import CoveyKit
import CoveyGit
import Darwin
@testable import covey

final class DocumentFileAccessTests: XCTestCase {
    func testLinksAndContainment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let context = DocumentContext(sourceSession:"a",root:root.path,projectKey:root.path)
        XCTAssertEqual(try DocumentLinkResolver.resolve("../план%20v1.md#этап",from:"docs/a.md",context:context), .local(path:"план v1.md",fragment:"этап"))
        XCTAssertThrowsError(try DocumentLinkResolver.resolve("../../outside.md",from:"docs/a.md",context:context))
        XCTAssertThrowsError(try DocumentLinkResolver.resolve("javascript:alert(1)",from:"a.md",context:context))
        XCTAssertEqual(try DocumentLinkResolver.fileURL(path:"name#literal.md",context:context).lastPathComponent,"name#literal.md")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("outside"),withDestinationURL:root.deletingLastPathComponent())
        XCTAssertThrowsError(try DocumentLinkResolver.fileURL(path:"outside/secret",context:context))
        XCTAssertThrowsError(try DocumentLinkResolver.fileURL(path:root.path + "-sibling/a",context:context))
        XCTAssertThrowsError(try DocumentLinkResolver.resolve("/tmp/outside.md",from:"docs/a.md",context:context))
        XCTAssertEqual(try DocumentLinkResolver.resolve("#section",from:"docs/a.md",context:context), .local(path:"docs/a.md",fragment:"section"))
    }
    func testBoundedTextBinaryAndDirectRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let c = DocumentContext(sourceSession:"a",root:root.path,projectKey:root.path)
        try Data("# ignored plan".utf8).write(to:root.appendingPathComponent("plan.md"))
        let text = try await DocumentFileLoader().load(path:"plan.md",context:c)
        XCTAssertEqual(text,.text(path:"plan.md",text:"# ignored plan",isMarkdown:true,byteCount:14))
        try Data([0,1,2]).write(to:root.appendingPathComponent("binary"))
        let binary = try await DocumentFileLoader().load(path:"binary",context:c)
        XCTAssertEqual(binary,.binary(path:"binary",byteCount:3))
        try Data(repeating:65,count:4 * 1024 * 1024 + 1).write(to:root.appendingPathComponent("large"))
        let large = try await DocumentFileLoader().load(path:"large",context:c)
        XCTAssertEqual(large,.tooLarge(path:"large",byteCount:4 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try DocumentLinkResolver.fileURL(path:"../x",context:c))
        XCTAssertEqual(DocumentFileLoader.maxPreviewBytes, 4 * 1024 * 1024)
        try Data(repeating:65,count:DocumentFileLoader.maxPreviewBytes).write(to:root.appendingPathComponent("limit"))
        guard case .text(_, let content, _, let count) = try await DocumentFileLoader().load(path:"limit",context:c) else { return XCTFail("Exact limit must be readable") }
        XCTAssertEqual(content.count,count)
        try Data([0xff]).write(to:root.appendingPathComponent("invalid"))
        let invalid = try await DocumentFileLoader().load(path:"invalid",context:c)
        XCTAssertEqual(invalid,.binary(path:"invalid",byteCount:1))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("internal.md"),withDestinationURL:root.appendingPathComponent("plan.md"))
        let internalFile = try await DocumentFileLoader().load(path:"internal.md",context:c)
        XCTAssertEqual(internalFile,.text(path:"internal.md",text:"# ignored plan",isMarkdown:true,byteCount:14))
        for path in ["folder", "fifo"] {
            if path == "folder" { try FileManager.default.createDirectory(at:root.appendingPathComponent(path),withIntermediateDirectories:true) }
            else { XCTAssertEqual(mkfifo(root.appendingPathComponent(path).path,0o600),0) }
            do { _ = try await DocumentFileLoader().load(path:path,context:c); XCTFail("Special files must be rejected") }
            catch { XCTAssertTrue(error is DocumentAccessError) }
        }
    }
    func testRootUsesActualWorktreeAndNonGitFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let result = await DocumentRootResolver.resolve(directory:root.path,sessionName:"s",worktreeRepo:nil)
        XCTAssertTrue(result.usedDirectoryFallback)
        XCTAssertEqual(result.context.root,root.resolvingSymlinksInPath().path)
        try GitRunner.run(in:root.path,["init"],readOnly:false)
        let git = await DocumentRootResolver.resolve(directory:root.path,sessionName:"s",worktreeRepo:nil)
        XCTAssertFalse(git.usedDirectoryFallback)
        XCTAssertEqual(git.context.projectKey,git.context.root)
        try GitRunner.run(in:root.path,["-c","user.name=Test","-c","user.email=test@example.com","commit","--allow-empty","-m","init"],readOnly:false)
        let worktree = root.appendingPathComponent("branch")
        try GitRunner.run(in:root.path,["worktree","add","-b","document-test",worktree.path],readOnly:false)
        let branch = await DocumentRootResolver.resolve(directory:worktree.path,sessionName:"s",worktreeRepo:nil)
        XCTAssertEqual(branch.context.root,worktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(branch.context.projectKey,git.context.root)
    }
}
