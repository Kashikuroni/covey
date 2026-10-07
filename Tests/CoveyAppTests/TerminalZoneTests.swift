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

    func testToggleSpawnsHiddenShellAtAgentCwd() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }

        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)
        let s = try XCTUnwrap(daemon.registry.get(name: shell))
        XCTAssertEqual(s.dir, "/repo/.worktrees/feat")   // the agent's cwd, not the repo root
        XCTAssertEqual(s.hidden, true)
        XCTAssertNil(s.companionOf)
        XCTAssertFalse(model.visibleSessions.contains { $0.name == shell })
        XCTAssertNil(model.viewOfSession[shell])  // the shell is not a workspace-view session
    }

    func testToggleBelowOpensHorizontalZone() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal(axis: .horizontal)
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }
        XCTAssertEqual(model.activeView?.terminal?.axis, .horizontal)
        await model.kill(model.activeView!.terminal!.shellSession!)
    }

    func testToggleRotatesAxisKeepingTheShellAlive() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()   // ⌘T: right column
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }
        let shell = try XCTUnwrap(model.activeView?.terminal?.shellSession)

        await model.toggleActiveTerminal(axis: .horizontal)   // ⌘⇧T: rotate below
        XCTAssertEqual(model.activeView?.terminal?.axis, .horizontal)
        XCTAssertEqual(model.activeView?.terminal?.shellSession, shell,
                      "rotation must not respawn the shell")
        XCTAssertNotNil(daemon.registry.get(name: shell))

        await model.toggleActiveTerminal(axis: .horizontal)   // same axis again: close
        XCTAssertNil(model.activeView?.terminal)
        _ = await eventually { daemon.registry.get(name: shell) == nil }
    }

    func testToggleGivesTheColumnRoomAndFocusesIt() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await modelWithWorktreeSession(daemon)
        await model.toggleActiveTerminal()
        _ = await eventually { model.activeView?.terminal?.shellSession != nil }
        // Unsized (nil) resolves to a default that leaves room for the column;
        // a stored 1.0 would collapse it to zero width.
        XCTAssertLessThanOrEqual(model.activeView!.agentAreaRatio ?? 0.6, 0.85)
        XCTAssertEqual(model.focusedPane, model.activeView?.terminal?.shellSession)
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
