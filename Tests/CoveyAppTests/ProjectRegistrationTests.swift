import XCTest
@testable import covey
import CoveyKit
import CoveydCore

final class ProjectRegistrationTests: XCTestCase {
    @MainActor
    func testAddProjectRegistersDedupesAndSelects() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/x/")           // trailing slash: normalized away
        let selected = await eventually { model.selectedProjectRoot == "/repo/x" }
        XCTAssertTrue(selected)
        XCTAssertEqual(model.projects, ["/repo/x"])
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.inspectorRoot, "/repo/x")
        // No session: the issue browser must still get a dir to run gh in —
        // the project root itself — else it shows the prior project's issues.
        XCTAssertEqual(model.inspectorDir, "/repo/x")
        model.addProject("/repo/x")            // duplicate: no second entry
        XCTAssertEqual(model.projects, ["/repo/x"])
    }

    @MainActor
    func testSelectSessionClearsProjectSelection() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "s1")
        let (model, _) = try makeModel(daemon)
        await model.start()                    // lands on s1
        model.addProject("/repo/x")
        _ = await eventually { model.selectedProjectRoot == "/repo/x" }
        XCTAssertNil(model.selected, "ghost selection detaches the session")
        await model.select("s1")
        XCTAssertNil(model.selectedProjectRoot, "session selection clears the ghost")
        XCTAssertEqual(model.selected, "s1")
        XCTAssertEqual(model.inspectorRoot, "/tmp")
        XCTAssertEqual(model.inspectorDir, "/tmp")   // session selected: its dir
        daemon.registry.kill(name: "s1")
    }

    @MainActor
    func testRemoveProjectClearsSelection() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/x")
        _ = await eventually { model.selectedProjectRoot == "/repo/x" }
        model.removeProject("/repo/x")
        XCTAssertEqual(model.projects, [])
        XCTAssertNil(model.selectedProjectRoot)
        XCTAssertEqual(model.toast, "project removed")
    }

    @MainActor
    func testProjectsPersistAcrossRestart() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = daemon.path
        let statePath = "\(NSTemporaryDirectory())covey-proj-\(UInt32.random(in: 0..<UInt32.max)).json"
        let store = StateStore(path: statePath, debounce: 0.01)
        let client1 = IPCClient(path: path)
        try client1.connect()
        let model1 = AppModel(
            client: client1,
            makeClient: { let c = IPCClient(path: path); try c.connect(); return c },
            store: store)
        await model1.start()
        model1.addProject("/repo/x")
        store.flush()
        let client2 = IPCClient(path: path)
        try client2.connect()
        let model2 = AppModel(
            client: client2,
            makeClient: { let c = IPCClient(path: path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.01))
        await model2.start()
        XCTAssertEqual(model2.projects, ["/repo/x"])
    }

    @MainActor
    func testRemoveRightAfterAddDoesNotResurrectSelection() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/x")            // selection deferred via Task
        model.removeProject("/repo/x")         // races the deferred selection
        // Let the deferred task land, then require the selection stayed clear.
        _ = await eventually { model.projects.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.selectedProjectRoot,
                     "stale deferred selection must not resurrect a removed project")
    }

    @MainActor
    func testOrderedSessionsIncludesEmptyRegisteredProject() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "s1")
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/empty")
        _ = await eventually { model.selectedProjectRoot == "/repo/empty" }
        let groups = model.orderedSessions()
        XCTAssertEqual(groups.map(\.dir), ["/tmp", "/repo/empty"],
                       "live roots first, then registered-only")
        XCTAssertTrue(groups[1].sessions.isEmpty)
        daemon.registry.kill(name: "s1")
    }

    @MainActor
    func testProjectOrderAppliesToRegisteredProjects() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/b")
        model.addProject("/repo/a")
        _ = await eventually { model.selectedProjectRoot == "/repo/a" }
        XCTAssertEqual(model.orderedSessions().map(\.dir), ["/repo/b", "/repo/a"])
        model.moveProject(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(model.orderedSessions().map(\.dir), ["/repo/a", "/repo/b"])
    }

    @MainActor
    func testVisibleRowsGhostAndFilter() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "alpha")
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/empty")
        _ = await eventually { model.selectedProjectRoot == "/repo/empty" }
        XCTAssertEqual(model.visibleRows(),
                       [.session("alpha"), .ghost("/repo/empty")])
        model.setFilter("alp")
        XCTAssertEqual(model.visibleRows(), [.session("alpha")],
                       "ghosts hide while filtering")
        daemon.registry.kill(name: "alpha")
    }

    @MainActor
    func testStepWalksOntoGhostAndBack() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "alpha")
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/empty")
        _ = await eventually { model.selectedProjectRoot == "/repo/empty" }
        await model.select("alpha")
        model.apply(.selectNext)               // j: session -> ghost
        let onGhost = await eventually {
            model.selected == nil && model.selectedProjectRoot == "/repo/empty"
        }
        XCTAssertTrue(onGhost)
        model.apply(.selectPrev)               // k: ghost -> session
        let onSession = await eventually { model.selected == "alpha" }
        XCTAssertTrue(onSession)
        XCTAssertNil(model.selectedProjectRoot)
        daemon.registry.kill(name: "alpha")
    }

    @MainActor
    func testProjectScopedActionsWorkWithoutSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/x")
        _ = await eventually { model.selectedProjectRoot == "/repo/x" }

        model.perform(.createGitHubIssue)
        XCTAssertTrue(model.showInspector)
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.inspectorMode, .issues,
                       "a project ghost can still open the issue composer")

        model.perform(.newSessionInCurrentProject)
        XCTAssertEqual(model.newSessionPrefillDir, "/repo/x")
        XCTAssertEqual(model.modal, .newSession)

        model.modal = nil
        model.perform(.renameProject)
        XCTAssertEqual(model.modal, .renameProject("/repo/x"))
    }

    @MainActor
    func testAddProjectActionOpensSheet() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.perform(.addProject)
        // Opens the path-input sheet (AddProjectSheet), not a Finder panel;
        // registration happens on submit, so nothing is added by the action.
        XCTAssertEqual(model.modal, .addProject)
        XCTAssertEqual(model.inputMode, .normal)
        XCTAssertEqual(model.projects, [])
    }

    @MainActor
    func testRemoveProjectActionUsesInspectorRoot() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.addProject("/repo/x")
        _ = await eventually { model.selectedProjectRoot == "/repo/x" }
        model.perform(.removeProject)
        XCTAssertEqual(model.projects, [])
        XCTAssertNil(model.selectedProjectRoot)
    }

    @MainActor
    func testRemoveProjectActionWithNothingSelectedIsDisabled() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.perform(.removeProject)            // no session, no ghost selected
        XCTAssertEqual(model.commandAvailability(.removeProject),
                       .disabled(reason: "No project selected"))
        XCTAssertNil(model.toast)
        XCTAssertEqual(model.projects, [])
    }

}
