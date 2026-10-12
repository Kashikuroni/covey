import XCTest
import CoveyKit
@testable import covey

private actor ControlledDocumentCatalog: DocumentCatalogScanning {
    var requests: [CheckedContinuation<DocumentCatalogSnapshot, Error>] = []
    var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }
    func scan(context: DocumentContext, configuration: DocumentExclusionConfiguration) async throws -> DocumentCatalogSnapshot {
        try await withCheckedThrowingContinuation {
            requests.append($0)
            let ready = waiting.filter { $0.0 <= requests.count }
            waiting.removeAll { $0.0 <= requests.count }
            for (_, continuation) in ready { continuation.resume() }
        }
    }
    func waitForCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiting.append((count,$0)) }
    }
    func finish(_ index: Int, path: String) { requests[index].resume(returning:.init(entries:[.init(path:path,isMarkdown:true,byteCount:1)],detected:[.common],unreadableDirectories:[])) }
}

@MainActor final class DocumentWorkspaceTests: XCTestCase {
    func testOlderScanCannotPublishAfterManifestOrSettingsChange() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model,client) = try makeModel(daemon); defer { client.close() }
        await model.start()
        for name in ["a","b"] { _ = try daemon.registry.create(dir:"/tmp",agent:"claude",argv:["/bin/cat"],name:name) }
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        let original = try XCTUnwrap(model.activeViewID)
        let catalog = ControlledDocumentCatalog()
        model.documentCatalog = catalog
        let opening = Task { await model.openDocumentPicker() }
        await catalog.waitForCount(1)
        await model.select("b")
        model.documentExclusionSettings.apply(.init(global:.init(customRules:"excluded/")))
        await catalog.waitForCount(2)
        await catalog.finish(1,path:"new.md")
        _ = await eventually { model.documentPicker?.snapshot?.entries.first?.path == "new.md" }
        await catalog.finish(0,path:"old.md")
        await opening.value
        XCTAssertEqual(model.documentPicker?.snapshot?.entries.first?.path,"new.md")
        XCTAssertEqual(model.documentPicker?.viewID,original)
        await model.openDocument(path:"new.md",viewID:original)
        XCTAssertEqual(model.views[original]?.documents?.context.sourceSession,"a")
        XCTAssertNil(model.activeView?.documents)
        XCTAssertNil(model.documentReaders[original],"Hidden workspaces create readers only on activation")
        model.closeDocuments(viewID:original)
    }
    func testZonePersistsWithoutBecomingAgentPaneAndSurvivesSourceRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("# spec".utf8).write(to:root.appendingPathComponent("spec.md"))
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model,client) = try makeModel(daemon); defer { client.close() }
        await model.start()
        for name in ["a","b"] { _ = try daemon.registry.create(dir:root.path,agent:"claude",argv:["/bin/cat"],name:name) }
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        await model.splitFocusedPane(axis:.vertical,newSession:"b")
        model.focusPane("a")
        let id = try XCTUnwrap(model.activeViewID)
        await model.openDocumentPicker()
        XCTAssertEqual(model.documentPicker?.context?.sourceSession,"a")
        await model.openDocument(path:"spec.md",viewID:id)
        XCTAssertEqual(model.views[id]?.documents?.context.sourceSession,"a")
        XCTAssertEqual(model.agentPanes.sorted(),["a","b"])
        XCTAssertEqual(model.documentReaders[id]?.current?.path,"spec.md")
        XCTAssertEqual(WorkspaceView(persisted:try XCTUnwrap(model.views[id]?.persisted)).documents,model.views[id]?.documents)
        model.renameSessionInView("a",to:"renamed")
        XCTAssertEqual(model.views[id]?.documents?.context.sourceSession,"renamed")
        _ = model.removeSessionFromView("renamed")
        XCTAssertNotNil(model.views[id]?.documents)
        _ = model.removeSessionFromView("b")
        XCTAssertNil(model.documentReaders[id])
    }
    func testCommandsRespectSelectionZoneAndReview() {
        XCTAssertFalse(CommandRules.availability(for:.openProjectDocument,context:.init()).isEnabled)
        XCTAssertTrue(CommandRules.availability(for:.openProjectDocument,context:.init(hasSelectedSession:true)).isEnabled)
        XCTAssertTrue(CommandRules.availability(for:.closeDocumentView,context:.init(hasDocumentZone:true)).isEnabled)
        XCTAssertFalse(CommandRules.availability(for:.focusDocuments,context:.init(reviewOpen:true,hasDocumentZone:true)).isEnabled)
    }
}
