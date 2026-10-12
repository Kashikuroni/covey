import XCTest
@testable import CoveyKit

final class DocumentStateTests: XCTestCase {
    func testLegacyJSONLoadsWithoutDocuments() throws {
        let data = Data(#"{"recents":[],"order":[],"projectOrder":[],"projectNames":{},"drafts":{},"sessions":{}}"#.utf8)
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertNil(state.documentExclusions)
        XCTAssertNil(state.documentRecents)
        let view = try JSONDecoder().decode(PersistedWorkspaceView.self, from: Data(#"{"id":"v","agentTree":{"type":"agent","session":"a"}}"#.utf8))
        XCTAssertNil(view.documents)
    }

    func testZoneAndSettingsRoundTrip() throws {
        let context = DocumentContext(sourceSession: "a", root: "/tmp/worktree", projectKey: "/tmp/repo")
        let zone = PersistedDocumentZone(context: context, location: .init(path: "docs/план.md", fragment: "этап", position: .init(anchorID: "этап", offset: 12, progress: 0.4)), width: 400, sourceMode: false)
        var view = PersistedWorkspaceView(id: "v", agentTree: .agent(session: "a"))
        view.documents = zone
        var state = PersistedState(workspaceViews: [view])
        state.documentExclusions = .init(global: .init(useBuiltins: true, presetOverrides: [.rust: false], customRules: "generated/"), projects: ["/tmp/repo": .init(useBuiltins: false, customRules: "!dist/")])
        state.documentRecents = [.init(root: context.root, paths: ["docs/план.md"])]
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: encoded), state)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("documentText"))
    }

    func testProjectNilOverridesPreserveInheritance() throws {
        let inherited = DocumentScopeExclusions()
        let disabled = DocumentScopeExclusions(useBuiltins: false)
        XCTAssertNil(try JSONDecoder().decode(DocumentScopeExclusions.self, from: JSONEncoder().encode(inherited)).useBuiltins)
        XCTAssertEqual(try JSONDecoder().decode(DocumentScopeExclusions.self, from: JSONEncoder().encode(disabled)).useBuiltins, false)
    }
}
