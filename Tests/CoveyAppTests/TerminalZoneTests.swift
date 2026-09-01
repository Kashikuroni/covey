import XCTest
@testable import covey
import CoveyKit

@MainActor final class TerminalZoneTests: XCTestCase {
    private func modelWithWorktreeSession(_ daemon: TestDaemon) async throws -> AppModel {
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/repo/.worktrees/feat", agent: "claude",
                                       argv: ["/bin/cat"], name: "a", worktreeRepo: "/repo")
        _ = await eventually { model.viewOfSession["a"] != nil }
        await model.select("a")
        return model
    }

    func testToggleSpawnsHiddenShellAtProjectRoot() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }

        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)
        let s = try XCTUnwrap(daemon.registry.get(name: shell))
        XCTAssertEqual(s.dir, "/repo")            // project root, not the worktree
        XCTAssertEqual(s.hidden, true)
        XCTAssertNil(s.companionOf)
        XCTAssertFalse(model.visibleSessions.contains { $0.name == shell })
        XCTAssertNil(model.viewOfSession[shell])  // the shell is not a workspace-view session
    }

    func testToggleTwiceClosesAndKillsShell() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }
        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)

        await model.toggleActiveTerminal()
        XCTAssertNil(model.activeView?.terminal)
        _ = await eventually { daemon.registry.get(name: shell) == nil }
    }

    func testShellExitClosesTheZoneWithoutACard() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }
        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)
        let visibleBefore = model.visibleSessions.count

        _ = try daemon.registry.kill(name: shell)
        _ = await eventually { model.activeView?.terminal == nil }
        XCTAssertEqual(model.visibleSessions.count, visibleBefore)
        XCTAssertNotNil(model.activeView, "the view itself survives")
    }

    func testShellRespawnsWhenDaemonLostIt() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        var seed = PersistedState()
        seed.workspaceViews = [PersistedWorkspaceView(
            id: "v1", agentTree: .agent(session: "a"),
            terminalShell: "s-gone", terminalOpen: true)]
        seed.viewOfSession = ["a": "v1"]
        let (model, _) = try makeModel(daemon, seed: seed)
        _ = try daemon.registry.create(dir: "/repo", agent: "claude", argv: ["/bin/cat"], name: "a")
        await model.start()
        await model.select("a")

        _ = await eventually { model.views["v1"]?.terminal?.shellSession != nil }
        let shell = try XCTUnwrap(model.views["v1"]?.terminal?.shellSession)
        XCTAssertNotEqual(shell, "s-gone")
        XCTAssertEqual(daemon.registry.get(name: shell)?.dir, "/repo")
    }
}
