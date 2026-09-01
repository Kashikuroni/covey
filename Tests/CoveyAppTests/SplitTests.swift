import XCTest
@testable import covey
import CoveyKit

// MARK: - Pane tree ratios / sanitize (pure-ish)

@MainActor final class PaneTreeStateTests: XCTestCase {
    func testSetSplitRatioWalksThePathAndClampsOnActiveView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newViewID = { "v1" }
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.viewOfSession["a"] != nil }
        await model.select("a")
        model.views["v1"]?.agentTree = .split(
            axis: .vertical, ratio: 0.5,
            first: .agent(session: "a"),
            second: .split(axis: .horizontal, ratio: 0.5,
                           first: .agent(session: "b"), second: .agent(session: "c")))

        model.setSplitRatio(path: [], ratio: 0.99)
        guard case .split(_, let root, _, _)? = model.activeView?.agentTree else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(root, 0.85, accuracy: 0.0001)

        model.setSplitRatio(path: [1], ratio: 0.01)
        guard case .split(_, _, _, let second)? = model.activeView?.agentTree,
              case .split(_, let inner, _, _) = second else {
            return XCTFail("nested not a split")
        }
        XCTAssertEqual(inner, 0.15, accuracy: 0.0001)
    }

    func testSanitizeDropsDeadLeavesFromRestoredView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        // Persisted view names a session the daemon no longer has.
        var seed = PersistedState()
        seed.workspaceViews = [PersistedWorkspaceView(
            id: "v1",
            agentTree: .split(axis: "vertical", ratio: 0.5,
                              first: .agent(session: "a"), second: .agent(session: "dead")))]
        seed.viewOfSession = ["a": "v1", "dead": "v1"]
        let (model, _) = try makeModel(daemon, seed: seed)
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        await model.start()
        XCTAssertEqual(model.views["v1"]?.leaves, ["a"])
        XCTAssertNil(model.viewOfSession["dead"])
    }
}

// MARK: - Split picker (sessions only)

@MainActor final class SplitPickerModelTests: XCTestCase {
    private func session(_ name: String, dir: String = "/tmp",
                         companionOf: String? = nil, hidden: Bool? = nil) -> Session {
        var s = Session(name: name, dir: dir, cwd: dir, agent: "claude", created: 0,
                        companionOf: companionOf)
        s.hidden = hidden
        return s
    }

    func testItemsAreProjectSessionsExcludingOccupiedForeignHidden() {
        let sessions = [
            session("a", dir: "/p"), session("b", dir: "/p"),
            session("other", dir: "/p"), session("foreign", dir: "/q"),
            session("shell", dir: "/p", hidden: true),
        ]
        let items = SplitPicker.items(projectSessions: sessions,
                                      occupied: ["a", "b"], projectRoot: "/p")
        XCTAssertEqual(items.map(\.kind), [.session("other")])
    }

    func testItemsExcludeTheSoloPane() {
        let sessions = [session("a", dir: "/p"), session("other", dir: "/p")]
        let items = SplitPicker.items(projectSessions: sessions, occupied: ["a"],
                                      projectRoot: "/p")
        XCTAssertEqual(items.map(\.kind), [.session("other")])
    }
}

// MARK: - Split flow (integration with the daemon)

@MainActor final class SplitFlowTests: XCTestCase {
    private func threeSessions(_ daemon: TestDaemon,
                              names: [String] = ["a", "b", "c"]) async throws -> AppModel {
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in names {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.viewOfSession.count == names.count }
        return model
    }

    func testPickerSplitFocusesNewPaneAndAttaches() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await threeSessions(daemon, names: ["a", "b"])
        await model.select("a")
        model.perform(.splitTerminalVertically)
        XCTAssertEqual(model.modal, .splitPicker(.vertical))
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        XCTAssertEqual(model.activeView?.leaves.sorted(), ["a", "b"])
        XCTAssertEqual(model.focusedPane, "b")
        XCTAssertEqual(model.selected, "b")
        XCTAssertTrue(model.attachedNames.contains("b"))
    }

    func testPickerFollowsSidebarOrderAndHidesTheOpenPane() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await threeSessions(daemon)
        await model.select("a")
        model.moveSession(inDir: "/tmp", from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.splitPickerItems(for: .vertical).map(\.kind),
                       [.session("c"), .session("b")])
    }

    func testSelectOutsideTheSplitHidesTheGridSelectBackRestores() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await threeSessions(daemon)
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")

        await model.select("c")
        XCTAssertEqual(model.agentPanes, ["c"])
        XCTAssertNil(model.visibleSplitTree)
        XCTAssertEqual(model.viewForSession("a")?.leaves.sorted(), ["a", "b"], "split remembered")
        XCTAssertFalse(model.attachedNames.contains("a"))
        XCTAssertTrue(model.attachedNames.contains("c"))

        await model.select("a")
        XCTAssertEqual(model.agentPanes.sorted(), ["a", "b"])
        XCTAssertEqual(model.focusedPane, "a")
        XCTAssertTrue(model.attachedNames.contains("b"))
        XCTAssertFalse(model.attachedNames.contains("c"))
    }

    func testCmdWReturnsAgentToItsOwnViewSessionStaysAlive() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await threeSessions(daemon, names: ["a", "b"])
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")
        model.perform(.closeTerminalSplit)
        XCTAssertFalse(model.activeView?.isSplit ?? true)
        XCTAssertEqual(model.selected, "a")
        XCTAssertNotNil(daemon.registry.get(name: "b"))
        XCTAssertNotEqual(model.viewOfSession["a"], model.viewOfSession["b"])
    }

    func testExitedSessionAutoRepairsTheView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "sleep", argv: ["/bin/sleep", "0.2"], name: "b")
        _ = await eventually { model.viewOfSession.count == 2 }
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")
        let repaired = await eventually {
            model.sessions.first { $0.name == "b" } == nil
                && !(model.activeView?.isSplit ?? true)
        }
        XCTAssertTrue(repaired)
    }

    func testRenameMigratesTheViewTree() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await threeSessions(daemon, names: ["a", "b"])
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")
        await model.rename("b", to: "bb")
        XCTAssertEqual(model.activeView?.leaves.sorted(), ["a", "bb"])
    }

    func testLimitEightDisablesSplitCommands() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for i in 1...8 {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: "s\(i)")
        }
        _ = await eventually { model.viewOfSession.count == 8 }
        await model.select("s1")
        for i in 2...8 {
            await model.splitFocusedPane(axis: .vertical, newSession: "s\(i)")
        }
        XCTAssertEqual(model.agentPaneCount, 8)
        XCTAssertEqual(model.commandAvailability(.splitTerminalVertically),
                       .disabled(reason: "Split limit reached (8 panes)"))
    }
}

// MARK: - Legacy migration

@MainActor final class SplitMigrationFlowTests: XCTestCase {
    func testLegacyCompanionPairMigratesIntoAViewTerminal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        var seed = PersistedState()
        seed.splitTree = .split(axis: "vertical", ratio: 0.5,
                                first: .agent(session: "a"), second: .agent(session: "b"))
        seed.companionShell = "a+sh"
        seed.companionRatio = 0.55
        let (model, _) = try makeModel(daemon, seed: seed)
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"],
                                       name: "a+sh", companionOf: "a")
        await model.start()

        let view = try XCTUnwrap(model.views.values.first { $0.leaves.sorted() == ["a", "b"] })
        XCTAssertEqual(view.terminal?.shellSession, "a+sh")
        XCTAssertEqual(view.agentAreaRatio, 0.55, accuracy: 0.0001)
        XCTAssertNil(model.persisted.splitTree)
        XCTAssertNil(model.persisted.companionShell)
    }
}
