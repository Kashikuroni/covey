import XCTest
@testable import covey
import CoveyKit

// MARK: - Pane tree state (Split Session)

@MainActor final class PaneTreeStateTests: XCTestCase {
    func testSelectPerformsPointSwapNotDetachAll() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        await model.select("b")
        XCTAssertEqual(model.selected, "b")
        XCTAssertEqual(model.attachedNames, ["b"], "старая панель отвязана точечно")
    }

    func testFocusPaneKeepsSelectedInvariantOnAgentAndShell() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"],
                                       name: "a+sh", companionOf: "a")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        model.splitTree = .split(axis: .vertical, ratio: 0.5,
                                 first: .agent(session: "a"), second: .agent(session: "x"))
        model.companionShell = "a+sh"
        model.focusPane("a+sh")
        XCTAssertEqual(model.focusedPane, "a+sh")
        XCTAssertEqual(model.selected, "a", "фокус на колонке не меняет selected")
        model.focusPane("x")
        XCTAssertEqual(model.selected, "x", "selected следует за фокусной agent-панелью")
    }

    func testSetSplitRatioWalksThePathAndClamps() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.splitTree = .split(axis: .vertical, ratio: 0.5,
                                 first: .agent(session: "a"),
                                 second: .split(axis: .horizontal, ratio: 0.5,
                                                first: .agent(session: "b"),
                                                second: .agent(session: "c")))
        model.setSplitRatio(path: [], ratio: 0.99)   // пустой путь — корень
        guard case .split(_, let root, _, _) = model.splitTree! else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(root, 0.85, accuracy: 0.0001)
        model.setSplitRatio(path: [1], ratio: 0.01)  // вложенный узел
        guard case .split(_, _, _, let second) = model.splitTree! else {
            return XCTFail("not a split")
        }
        guard case .split(_, let inner, _, _) = second else {
            return XCTFail("second not a split")
        }
        XCTAssertEqual(inner, 0.15, accuracy: 0.0001)
        model.setCompanionRatio(0.01)
        XCTAssertEqual(model.companionRatio, 0.15, accuracy: 0.0001)
    }

    func testSanitizeDropsDeadLeavesFromRestoredTree() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.sessions.count == 1 }
        // Как будто восстановили из state.json дерево с мёртвым листом
        // "x" и мёртвой колонкой "x+sh".
        model.splitTree = .split(axis: .vertical, ratio: 0.5,
                                 first: .agent(session: "a"), second: .agent(session: "x"))
        model.companionShell = "x+sh"
        model.sanitizeSplitTree()
        XCTAssertNil(model.splitTree, "мёртвый лист схлопнул дерево до одного листа → nil")
        XCTAssertNil(model.companionShell, "мёртвая колонка сброшена")
    }
}

// MARK: - Picker model (чистая логика)

@MainActor final class SplitPickerModelTests: XCTestCase {
    private func session(_ name: String, dir: String = "/tmp",
                         companionOf: String? = nil) -> Session {
        Session(name: name, dir: dir, cwd: dir, agent: "claude", created: 0,
                companionOf: companionOf)
    }

    func testItemsTerminalFirstThenProjectSessionsExcludingTreeAndHidden() {
        let sessions = [
            session("a", dir: "/p"), session("b", dir: "/p"),
            session("other", dir: "/p"), session("foreign", dir: "/q"),
            session("hidden", dir: "/p", companionOf: "a"),
        ]
        let tree = PaneNode.split(axis: .vertical, ratio: 0.5,
                                  first: .agent(session: "a"), second: .agent(session: "b"))
        let items = SplitPicker.items(projectSessions: sessions, tree: tree,
                                      companionShell: nil, companionRoot: nil,
                                      projectRoot: "/p")
        XCTAssertEqual(items.map(\.kind), [.terminal, .session("other")],
                       "a и b уже в дереве, hidden невидим, /q чужой проект")
    }

    func testTerminalDecisionFocusCreateReplace() {
        XCTAssertEqual(SplitPicker.terminalDecision(
            companionShell: "s", companionRoot: "/p", projectRoot: "/p"), .focusExisting)
        XCTAssertEqual(SplitPicker.terminalDecision(
            companionShell: nil, companionRoot: nil, projectRoot: "/p"), .create)
        XCTAssertEqual(SplitPicker.terminalDecision(
            companionShell: "s", companionRoot: "/q", projectRoot: "/p"),
            .replaceForeign(oldShell: "s"))
    }
}

// MARK: - Split flow (интеграция с демоном)

@MainActor final class SplitFlowTests: XCTestCase {
    func testPickerSplitFocusesNewPaneAndAttaches() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        model.perform(.splitTerminalVertically)   // открывает модалку
        XCTAssertEqual(model.modal, .splitPicker(.vertical))
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        guard case .split(_, _, let first, let second)? = model.splitTree else {
            return XCTFail("expected tree")
        }
        XCTAssertEqual(first, .agent(session: "a"))
        XCTAssertEqual(second, .agent(session: "b"))
        XCTAssertEqual(model.focusedPane, "b")
        XCTAssertEqual(model.selected, "b")
        XCTAssertTrue(model.attachedNames.contains("b"))
    }

    func testTerminalChoiceCreatesShellAtProjectRootAndTakesColumn() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("a")
        model.perform(.splitTerminalHorizontally)
        await model.splitPickerChosen(.init(kind: .terminal, label: "Терминал"))
        let shellAppeared = await eventually {
            model.companionShell == "a+sh" && model.focusedPane == "a+sh"
        }
        XCTAssertTrue(shellAppeared)
        XCTAssertEqual(daemon.registry.get(name: "a+sh")?.dir,
                       daemon.registry.get(name: "a")?.dir,
                       "шелл в корне проекта (тестовый корень = dir сессии)")
    }

    func testSecondTerminalChoiceRefocusesInsteadOfDuplicating() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("a")
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .terminal, label: "Терминал"))
        _ = await eventually { model.companionShell == "a+sh" }
        await model.focusPane("a")                        // фокус с колонки на агента
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .terminal, label: "Терминал"))
        _ = await eventually(timeout: 0.6) { model.focusedPane == "a+sh" }
        XCTAssertEqual(daemon.registry.list().count, 2, "второй шелл не создаётся")
    }

    func testCmdWRemovesAgentFromTreeSessionStaysAlive() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        // фокус на b: закрыть — b возвращается в список живой
        await model.focusPane("b")
        model.perform(.closeTerminalSplit)
        let collapsed = await eventually { model.splitTree == nil }
        XCTAssertTrue(collapsed)
        XCTAssertEqual(model.focusedPane, "a")
        XCTAssertEqual(model.selected, "a")
        XCTAssertNotNil(daemon.registry.get(name: "b"), "сессия жива")
        XCTAssertTrue(model.visibleSessionNames().contains("b"))
    }

    func testExitedSessionAutoRepairsTree() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "sleep", argv: ["/bin/sleep", "0.2"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        let died = await eventually { model.sessions.first { $0.name == "b" } == nil }
        XCTAssertTrue(died, "sleep завершается и тянет .exited")
        let repaired = await eventually { model.splitTree == nil && model.focusedPane == "a" }
        XCTAssertTrue(repaired, "дерево схлопнулось, фокус у наследника")
    }

    func testRenameMigratesTreeNodes() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        await model.select("a")
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        await model.rename("b", to: "bb")
        XCTAssertEqual(model.splitTree?.leaves, ["a", "bb"])
        XCTAssertEqual(model.focusedPane, "bb")
    }

    func testLimitEightDisablesSplitCommands() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "s1")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("s1")
        for i in 2...8 {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: "s\(i)")
        }
        _ = await eventually { model.sessions.count == 8 }
        for i in 2...8 {
            await model.splitPickerChosen(.init(kind: .session("s\(i)"), label: "s\(i)"))
        }
        XCTAssertEqual(model.agentPaneCount, 8)
        XCTAssertEqual(model.commandAvailability(.splitTerminalVertically),
                       .disabled(reason: "Split limit reached (8 panes)"))
    }
}
