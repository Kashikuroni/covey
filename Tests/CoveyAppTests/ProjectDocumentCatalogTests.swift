import XCTest
import CoveyKit
@testable import covey

final class ProjectDocumentCatalogTests: XCTestCase {
    func testIndependentCatalogAndStableMonorepoPresets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func write(_ path: String, _ text: String = "# plan") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:url)
        }
        try write(".gitignore","docs/\n")
        try write("docs/Plan.MD")
        try write(".codex/spec.markdown")
        try write(".git/internal")
        try write("target/a.md")
        try write(".next/cache.md")
        try write("apps/web/package.json", "{\"dependencies\":{\"next\":\"1\"}}")
        try write("crates/lib/Cargo.toml", "[package]")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("linked"),withDestinationURL:root.appendingPathComponent("docs"))
        let context = DocumentContext(sourceSession:"s",root:root.path,projectKey:root.path)
        let snapshot = try await ProjectDocumentCatalog().scan(context:context,configuration:.init())
        let paths = snapshot.entries.map(\.path)
        XCTAssertTrue(paths.contains("docs/Plan.MD"),"Paths: \(paths)")
        XCTAssertTrue(paths.contains(".codex/spec.markdown"))
        XCTAssertFalse(paths.contains("target/a.md"))
        XCTAssertFalse(paths.contains(".next/cache.md"))
        XCTAssertFalse(paths.contains(where: { $0.hasPrefix("linked/") || $0.hasPrefix(".git/") }))
        XCTAssertTrue(snapshot.detected.isSuperset(of:[.rust,.next,.react,.node]))
        try write("apps/web/package.json", "{\"dependencies\":{\"react\":\"1\"}}")
        let changed = try await ProjectDocumentCatalog().scan(context:context,configuration:.init())
        XCTAssertFalse(changed.detected.contains(.next))
        XCTAssertTrue(changed.entries.contains(where: { $0.path == ".next/cache.md" }))
    }
    func testMissingRootFailsAndCancellationStopsScan() async throws {
        let context = DocumentContext(sourceSession:"s",root:"/nonexistent/" + UUID().uuidString,projectKey:"p")
        do { _ = try await ProjectDocumentCatalog().scan(context:context,configuration:.init()); XCTFail("Missing root") }
        catch {}
        let task = Task { try await ProjectDocumentCatalog().scan(context:context,configuration:.init()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch {}
    }
    func testObserverDetectsNestedManifestAndStopsOnCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let changed = expectation(description:"Nested manifest changed")
        changed.assertForOverFulfill = false
        let token = DocumentCatalogWatcher().observe(root:root.path) { changed.fulfill() }
        try Data("{}".utf8).write(to:root.appendingPathComponent("nested/package.json"))
        await fulfillment(of:[changed],timeout:5)
        token.cancel()
        token.cancel()
        try Data("{}".utf8).write(to:root.appendingPathComponent("nested/package.json"))
    }
}
