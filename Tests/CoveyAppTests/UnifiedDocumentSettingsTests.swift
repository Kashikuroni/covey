import XCTest
import CoveyKit
import SwiftUI
@testable import covey

private actor PreviewCatalog: DocumentCatalogScanning {
    private var requests: [CheckedContinuation<DocumentCatalogSnapshot,Error>] = []
    private var waiters: [(Int,CheckedContinuation<Void,Never>)] = []
    func scan(context: DocumentContext, configuration: DocumentExclusionConfiguration) async throws -> DocumentCatalogSnapshot {
        try await withCheckedThrowingContinuation {
            requests.append($0)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_,continuation) in ready { continuation.resume() }
        }
    }
    func waitFor(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count,$0)) }
    }
    func finish(_ index: Int, path: String) {
        requests[index].resume(returning:.init(entries:[],detected:[.common],unreadableDirectories:[],excludedPaths:[.init(path:path,isDirectory:true,decision:.init(excluded:true,source:.global(line:1),pattern:path+"/"))],excludedPathCount:1))
    }
}

@MainActor final class UnifiedDocumentSettingsTests: XCTestCase {
    func testOlderPreviewCannotReplaceNewRulesOrPublishAfterStop() async {
        let scanner = PreviewCatalog()
        let editor = DocumentExclusionEditor(settings:.init(),context:.init(sourceSession:"s",root:"/tmp",projectKey:"p"),scanner:scanner)
        let old = Task { await editor.refreshPreview() }
        await scanner.waitFor(1)
        editor.customRules = "new/"
        let new = Task { await editor.refreshPreview() }
        await scanner.waitFor(2)
        await scanner.finish(1,path:"new"); await new.value
        await scanner.finish(0,path:"old"); await old.value
        XCTAssertEqual(editor.preview?.excludedPaths.first?.path,"new")
        let stopped = Task { await editor.refreshPreview() }
        await scanner.waitFor(3)
        editor.stop()
        await scanner.finish(2,path:"stopped"); await stopped.value
        XCTAssertNil(editor.preview)
        XCTAssertFalse(editor.loading)
    }
    func testExcludedPreviewCapsPathsButKeepsTotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for index in 0..<205 { try Data([65]).write(to:root.appendingPathComponent("\(index).tmp")) }
        let context = DocumentContext(sourceSession:"s",root:root.path,projectKey:root.path)
        let snapshot = try await ProjectDocumentCatalog().scan(context:context,configuration:.init(global:.init(customRules:"*.tmp")))
        XCTAssertEqual(snapshot.excludedPaths.count,200)
        XCTAssertEqual(snapshot.excludedPathCount,205)
        XCTAssertTrue(snapshot.entries.isEmpty)
    }
    func testNativeRuleEditorAcceptsVimKeysAndUnicodeInNarrowPanel() async throws {
        for theme in [Theme.dark, .light] {
        let editor = DocumentExclusionEditor(settings:.init(),context:nil)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:640),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:ScrollView { DocumentExclusionsSettingsView(editor:editor,tk:Tokens(theme)).padding(16) }.preferredColorScheme(theme == .dark ? .dark : .light))
        window.contentView = host
        defer { window.close() }
        func textView(_ root: NSView) -> NSTextView? {
            if let text = root as? NSTextView, !text.isFieldEditor { return text }
            for child in root.subviews { if let result = textView(child) { return result } }
            return nil
        }
        let mounted = await eventually { textView(host) != nil }; XCTAssertTrue(mounted)
        let text = try XCTUnwrap(textView(host))
        window.makeFirstResponder(text)
        text.insertText("jklh\nправило/\n",replacementRange:NSRange(location:0,length:0))
        let typed = await eventually { editor.customRules == "jklh\nправило/\n" }; XCTAssertTrue(typed)
        XCTAssertEqual(editor.settings.configuration.global.customRules,"")
        XCTAssertLessThanOrEqual(text.enclosingScrollView?.frame.width ?? 0,360)
        }
    }
    func testRuleDraftApplyRevertAndImmediateSwitches() {
        let settings = DocumentExclusionSettings(configuration:.init(global:.init(customRules:"saved/")))
        let editor = DocumentExclusionEditor(settings:settings,context:.init(sourceSession:"s",root:"/tmp",projectKey:"p"))
        editor.customRules = "draft/"
        editor.update { $0.presetOverrides[.swift] = true }
        XCTAssertEqual(settings.configuration.global.customRules,"saved/")
        XCTAssertEqual(settings.configuration.global.presetOverrides[.swift],true)
        XCTAssertTrue(editor.isDirty)
        editor.scope = .project("p")
        editor.customRules = "project/"
        editor.applyRules()
        XCTAssertEqual(settings.configuration.projects["p"]?.customRules,"project/")
        editor.scope = .global
        XCTAssertEqual(editor.customRules,"draft/")
        editor.customRules = "[invalid"
        editor.applyRules()
        XCTAssertEqual(settings.configuration.global.customRules,"saved/")
        XCTAssertFalse(editor.diagnostics.isEmpty)
        editor.revertRules()
        XCTAssertEqual(editor.customRules,"saved/")
        XCTAssertFalse(editor.isDirty)
        editor.customRules = "new/"
        editor.applyRules()
        XCTAssertEqual(settings.configuration.global.customRules,"new/")
    }
    func testSwiftPresetAndExcludedPathsExplainPrunedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func write(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("test".utf8).write(to:url)
        }
        for path in ["Package.swift",".build/debug/log.md",".swiftpm/state.json","build/output.md","DerivedData/cache.md","App.xcodeproj/project.pbxproj","App.xcodeproj/xcuserdata/user.xcuserdatad/debug.md","notes.md"] { try write(path) }
        let context = DocumentContext(sourceSession:"s",root:root.path,projectKey:root.path)
        let result = try await ProjectDocumentCatalog().scan(context:context,configuration:.init())
        XCTAssertTrue(result.detected.contains(.swift))
        XCTAssertTrue(result.entries.contains(where: { $0.path == "App.xcodeproj/project.pbxproj" }))
        XCTAssertTrue(result.entries.contains(where: { $0.path == "notes.md" }))
        let excluded = try XCTUnwrap(result.excludedPaths.first(where: { $0.path == ".build" }))
        XCTAssertTrue(excluded.isDirectory)
        XCTAssertEqual(excluded.decision.pattern,".build/")
        XCTAssertEqual(excluded.decision.source,.builtin("swift"))
        XCTAssertFalse(result.excludedPaths.contains(where: { $0.path.hasPrefix(".build/") }),"Pruned contents are not scanned")
        var config = DocumentExclusionConfiguration()
        config.projects[root.path] = .init(customRules:"!.build/\nnotes.md")
        let overridden = try await ProjectDocumentCatalog().scan(context:context,configuration:config)
        XCTAssertTrue(overridden.entries.contains(where: { $0.path == ".build/debug/log.md" }))
        XCTAssertEqual(overridden.excludedPaths.first(where: { $0.path == "notes.md" })?.decision.source,.project(line:2))
    }
    func testXcodeDetectionWithoutPackageManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("App.xcworkspace"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertTrue(DocumentPresets.detect(directory:root).contains(.swift))
    }
    func testMenuSettingsOpensGearPanel() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model,client) = try makeModel(daemon); defer { client.close() }
        await model.start()
        model.perform(.settings)
        XCTAssertTrue(model.showDashboardSettings)
        XCTAssertNil(model.modal)
        model.setVimMode(false)
        model.setLinksOnFocus(false)
        model.setUsagePlacement(.left)
        model.store.flush()
        XCTAssertEqual(model.store.load().vimMode,false)
        XCTAssertEqual(model.store.load().linksOnFocus,false)
        XCTAssertEqual(model.store.load().usagePlacement,"left")
    }
}
