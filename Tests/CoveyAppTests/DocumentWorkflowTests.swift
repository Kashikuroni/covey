import XCTest
import SwiftUI
import CoveyKit
import CoveyGit
import WebKit
@testable import covey

private actor OnceDocumentLoader: DocumentFileLoading {
    let text: String
    private var calls = 0
    init(_ text: String) { self.text = text }
    func load(path: String, context: DocumentContext) async throws -> DocumentFileSnapshot {
        calls += 1
        guard calls == 1 else { throw DocumentAccessError.unavailable }
        return .text(path:path,text:text,isMarkdown:true,byteCount:text.utf8.count)
    }
}

@MainActor final class DocumentWorkflowTests: XCTestCase {
    func testSwitchingWorkspaceWithFailedRefreshShowsItsOwnCachedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let daemon = try TestDaemon(); defer { daemon.stop() }
        for name in ["a","b"] { _ = try daemon.registry.create(dir:root.path,agent:"claude",argv:["/bin/cat"],name:name) }
        let (model,client) = try makeModel(daemon); defer { client.close() }
        await model.start(); await model.select("a")
        for name in ["a","b"] {
            let context = DocumentContext(sourceSession:name,root:root.path,projectKey:root.path)
            let reader = DocumentReaderModel(context:context,loader:OnceDocumentLoader("# \(name.uppercased()) workspace"))
            await reader.open(.init(path:"spec.md"))
            let id = try XCTUnwrap(model.viewOfSession[name])
            model.mutateForView(id) { $0.documents = .init(context:context,location:reader.current) }
            model.documentReaders[id] = reader
        }
        defer { for reader in model.documentReaders.values { reader.stop() } }
        let host = NSHostingView(rootView:TerminalPaneView(model:model))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func web(_ root: NSView) -> WKWebView? {
            if let result = root as? WKWebView { return result }
            for child in root.subviews { if let result = web(child) { return result } }
            return nil
        }
        func displays(_ text: String) async -> Bool {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if let view = web(host), let content = try? await view.evaluateJavaScript("document.getElementById('document')?.innerText"),
                   let string = content as? String, string.contains(text) { return true }
                try? await Task.sleep(for:.milliseconds(20))
            }
            return false
        }
        let a = await displays("A workspace"); XCTAssertTrue(a)
        await model.select("b")
        let reader = try XCTUnwrap(model.activeViewID.flatMap { model.documentReaders[$0] })
        XCTAssertEqual(reader.revision,1)
        XCTAssertNotNil(reader.error)
        let b = await displays("B workspace"); XCTAssertTrue(b,"Failed refresh must retain B's own cached document, never A's presentation")
    }
    func testIgnoredWorktreePlanUpdatesExclusionsRestoreAndMissingRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try GitRunner.run(in:root.path,["init"],readOnly:false)
        try Data("docs/\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try GitRunner.run(in:root.path,["add",".gitignore"],readOnly:false)
        try GitRunner.run(in:root.path,["-c","user.name=Test","-c","user.email=test@example.com","commit","-m","init"],readOnly:false)
        let branch = root.appendingPathComponent("worktree")
        try GitRunner.run(in:root.path,["worktree","add","-b","documents",branch.path],readOnly:false)
        func write(_ base: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at:base.appendingPathComponent("docs"),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:base.appendingPathComponent("docs/план.md"),options:.atomic)
        }
        try write(root,"# Main plan")
        try write(branch,"# Worktree plan")
        let daemon = try TestDaemon(); defer { daemon.stop() }
        for (name,dir) in [("branch",branch.path),("main",root.path)] {
            _ = try daemon.registry.create(dir:dir,agent:"claude",argv:["/bin/cat"],name:name)
        }
        let (model,client) = try makeModel(daemon); defer { client.close() }
        await model.start()
        await model.select("branch")
        let viewID = try XCTUnwrap(model.activeViewID)
        await model.openDocumentPicker()
        XCTAssertTrue(model.documentPicker?.snapshot?.entries.contains(where: { $0.path == "docs/план.md" }) == true)
        await model.openDocument(path:"docs/план.md",viewID:viewID)
        let reader = try XCTUnwrap(model.documentReaders[viewID])
        defer { reader.stop() }
        XCTAssertEqual(reader.context.root,branch.resolvingSymlinksInPath().path)
        XCTAssertEqual(reader.context.projectKey,root.resolvingSymlinksInPath().path)
        XCTAssertEqual(reader.snapshot,.text(path:"docs/план.md",text:"# Worktree plan",isMarkdown:true,byteCount:15))
        await model.select("main")
        try write(branch,"# Updated worktree plan")
        XCTAssertEqual(model.views[viewID]?.documents?.context.root,reader.context.root)
        await model.select("branch")
        XCTAssertEqual(reader.snapshot,.text(path:"docs/план.md",text:"# Updated worktree plan",isMarkdown:true,byteCount:23))
        var settings = model.settingsValues
        settings.documentExclusions.projects[reader.context.projectKey] = .init(customRules:"docs/")
        model.applySettings(settings)
        await model.openDocumentPicker()
        XCTAssertFalse(model.documentPicker?.snapshot?.entries.contains(where: { $0.path == "docs/план.md" }) == true)
        await model.openDocument(path:"docs/план.md",viewID:viewID)
        XCTAssertNil(reader.error,"Exact-path opening bypasses catalog exclusions")
        reader.recordPosition(.init(anchorID:"updated-worktree-plan",offset:0,progress:0.5))
        model.persistWorkspaceViews(); model.store.flush()
        let seed = model.store.load()
        XCTAssertEqual(seed.documentExclusions,settings.documentExclusions)
        let (restored,restoredClient) = try makeModel(daemon,seed:seed)
        defer { restoredClient.close(); for r in restored.documentReaders.values { r.stop() } }
        await restored.start()
        await restored.select("branch")
        let restoredReader = try XCTUnwrap(restored.documentReaders[viewID])
        XCTAssertEqual(restoredReader.context,reader.context)
        XCTAssertEqual(restoredReader.current?.position?.anchorID,"updated-worktree-plan")
        XCTAssertEqual(restoredReader.snapshot,reader.snapshot)
        XCTAssertEqual(model.agentPanes,["branch"])
        let index = try GitRunner.run(in:branch.path,["diff","--cached","--name-only"],readOnly:true)
        XCTAssertEqual(index,"")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("docs/план.md"),encoding:.utf8),"# Main plan")
        try FileManager.default.removeItem(at:branch)
        await reader.refresh()
        XCTAssertNotNil(reader.error)
        guard case .text(_,let retained,_,_) = reader.snapshot else { return XCTFail("Last good text") }
        XCTAssertEqual(retained,"# Updated worktree plan","Never fall back to main repository after worktree deletion")
        model.closeDocuments(viewID:viewID)
        XCTAssertNil(model.views[viewID]?.documents)
    }
}
