import XCTest
@testable import covey
import CoveyKit
import Foundation

final class AppModelChromeTests: XCTestCase {
    @MainActor
    func testCountsByStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        // statuses arrive from the daemon poller over time; assert total here and
        // running/waiting counters are derived (0 by default before any tick).
        XCTAssertEqual(model.counts.total, 2)
        for s in model.sessions { await model.kill(s.name) }
    }

    @MainActor
    func testOrderedSessionsRespectsOrder() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        // default order = by created (s1 then s2)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s1", "s2"])
        // move s2 before s1
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testMoveSessionPersists() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        store.flush()
        XCTAssertEqual(store.load().order, ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testShowFlagsPersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setShowFooter(false)
        model.setShowHeader(false)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showFooter, false)
        XCTAssertEqual(reloaded.showHeader, false)
    }

    @MainActor
    func testHistoryModeResetsOnSelect() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.setHistoryMode(true)
        XCTAssertTrue(model.historyMode)
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        let other = model.sessions.first { $0.name != name }!.name
        await model.select(other)
        XCTAssertFalse(model.historyMode, "history mode must reset on session switch")
        await model.kill(name); await model.kill(other)
    }

    @MainActor
    func testInspectorAndVimStatePersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-inspector-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertFalse(model.showInspector)
        XCTAssertEqual(model.sbWidth, 360)
        XCTAssertTrue(model.vimMode, "vim mode is on by default since slice 12")
        model.setShowInspector(true)
        model.setSbWidth(420)
        model.setVimMode(true)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showInspector, true)
        XCTAssertEqual(reloaded.sbWidth, 420)
        XCTAssertEqual(reloaded.vimMode, true)
        // A fresh model over the same store loads them back.
        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let model2 = AppModel(client: client2,
                              makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                              store: StateStore(path: path, debounce: 0.05))
        await model2.start()
        XCTAssertTrue(model2.showInspector)
        XCTAssertEqual(model2.sbWidth, 420)
        XCTAssertTrue(model2.vimMode)
    }

    @MainActor
    func testSbWidthClampsAndFocusInspector() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.setSbWidth(100)
        XCTAssertEqual(model.sbWidth, 240)
        model.setSbWidth(9000)
        XCTAssertEqual(model.sbWidth, 600)
        model.setFocus(.inspector)
        XCTAssertEqual(model.focus, .inspector)
    }

    @MainActor
    func testApplyNavigationWalksVisibleSessions() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s3")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 3 }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s2" }
        model.apply(.selectPrev)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectByNumber(3))
        _ = await eventually { model.selected == "s3" }
        model.apply(.selectFirst)
        _ = await eventually { model.selected == "s1" }
        // filter narrows navigation
        model.setFilter("s3")
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s3" }
        model.setFilter("")
        for s in model.sessions { daemon.registry.kill(name: s.name) }
    }

    @MainActor
    func testApplyModeTransitionsAndModals() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openLeader)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.leaderDescend(.session))
        XCTAssertEqual(model.inputMode, .leader(.session))
        model.apply(.leaderBack)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.closeOverlay)
        XCTAssertEqual(model.inputMode, .normal)
        model.apply(.enterSelectMode)
        XCTAssertEqual(model.inputMode, .selectSession)
        model.apply(.closeOverlay)
        model.apply(.showHelp)
        XCTAssertEqual(model.inputMode, .help)
        model.apply(.closeOverlay)
        model.apply(.newSession(prefillDir: false))
        XCTAssertEqual(model.modal, .newSession)
        model.modal = nil
        model.apply(.resizeSplit(3))
        XCTAssertEqual(model.splitPct, 41)   // 38 default + 3
    }

    @MainActor
    func testSlashActivatesFooterFilterAndEscapeClears() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertFalse(model.filterActive)
        model.apply(.startFilter)
        XCTAssertTrue(model.filterActive)
        model.setFilter("abc")
        model.filterEscape()
        XCTAssertFalse(model.filterActive)
        XCTAssertEqual(model.filter, "")
    }

    @MainActor
    func testApplyKillRenameNeedSelection() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.killSelected)
        XCTAssertNil(model.modal, "no selection — no kill sheet")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.killSelected)
        XCTAssertEqual(model.modal, .kill(name))
        model.modal = nil
        model.apply(.renameSelected)
        XCTAssertEqual(model.modal, .rename(name))
        model.modal = nil
        await model.kill(name)
    }

    @MainActor
    func testNotesPersistAndCounters() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-notes-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setNote(session: "s1", text: "- [ ] a\n- [x] b")
        model.setProjectNote(dir: "/w", text: "- [ ] p")
        model.setProjectName(dir: "/w", name: "Web")
        store.flush()
        let back = store.load()
        XCTAssertEqual(back.notes["s1"], "- [ ] a\n- [x] b")
        XCTAssertEqual(back.projectNotes["/w"], "- [ ] p")
        XCTAssertEqual(back.projectNames["/w"], "Web")
        XCTAssertEqual(model.displayName(forDir: "/w"), "Web")
        model.setNote(session: "s1", text: "")
        model.setProjectName(dir: "/w", name: "")
        store.flush()
        XCTAssertNil(store.load().notes["s1"], "empty note drops the key")
        XCTAssertNil(store.load().projectNames["/w"], "empty name drops the override")
    }

    @MainActor
    func testNoteToggleFlowAndEditing() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.toggleSessionNote)
        XCTAssertEqual(model.noteTarget, .session(name))
        XCTAssertEqual(model.inputMode, .note)
        XCTAssertTrue(model.showInspector, "opening a note reveals the inspector")
        model.apply(.toggleSessionNote)
        XCTAssertNil(model.noteTarget, "second t closes")
        XCTAssertEqual(model.inputMode, .normal)
        model.apply(.toggleProjectNote)
        XCTAssertEqual(model.noteTarget, .project("/a"))
        model.setNoteText("- [ ] one\n- [ ] two")
        model.apply(.noteToggleTask)
        XCTAssertEqual(taskCounts(model.noteText()).done, 1)
        model.apply(.noteCursor(down: true))
        model.apply(.noteVisual)
        model.apply(.noteCursor(down: false))
        model.apply(.noteDelete)
        XCTAssertEqual(taskCounts(model.noteText()).total, 0, "visual delete removes both")
        model.setNoteText("- [ ] x")
        model.apply(.noteArmClear)
        model.apply(.noteCursor(down: true))   // any non-y key disarms, does nothing else
        XCTAssertEqual(model.noteText(), "- [ ] x")
        model.apply(.noteArmClear)
        model.apply(.noteYank)                 // armed + y wipes
        XCTAssertEqual(model.noteText(), "")
        model.apply(.noteEscape)
        XCTAssertNil(model.noteTarget)
        await model.kill(name)
    }

    @MainActor
    func testExitedSessionCarriesResumeIntoRecentsAndRelaunch() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // A "claude-like" session with a saved resume command.
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                                       name: "res", resumeCmd: "claude --resume abc")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 1 }
        XCTAssertEqual(model.sessions[0].resumeCmd, "claude --resume abc")
        daemon.registry.kill(name: "res")
        _ = await eventually { model.sessions.isEmpty }
        XCTAssertEqual(model.recents.first?.resumeCmd, "claude --resume abc",
                       "exit path must carry the resume command into recents")
        // Relaunch resumes: the daemon runs the saved command (cat is fine here —
        // we only assert the create round-trips with the resume argv).
        await model.relaunchRecent(model.recents.first!)
        _ = await eventually { model.sessions.count == 1 }
        XCTAssertEqual(model.sessions[0].resumeCmd, "claude --resume abc",
                       "a resumed session stays resumable")
        daemon.registry.kill(name: "res")
        _ = await eventually { model.sessions.isEmpty }
    }

    @MainActor
    func testGitActionGuardsAndGitChangedEvent() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // Plain session in a non-repo dir: promote refused, delete needs git.
        await model.create(dir: "/tmp", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.promoteSelected)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast, "not a worktree session")
        model.apply(.deleteBranchSelected)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast, "no git info")
        model.apply(.cleanupBranches)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast, "not a git repo")
        // gitChanged fills the card info; a protected branch blocks delete.
        daemon.gitMonitor.onGitChanged?(name, GitInfo(branch: "main", added: 1, removed: 0))
        _ = await eventually { model.sessions.first?.git?.branch == "main" }
        model.apply(.deleteBranchSelected)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast, "branch 'main' is protected")
        model.apply(.cleanupBranches)
        XCTAssertEqual(model.modal, .cleanup("/tmp"))
        model.modal = nil
        await model.kill(name)
    }

    @MainActor
    func testRenameProjectModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        await model.select(model.sessions[0].name)
        model.apply(.renameProject)
        XCTAssertEqual(model.modal, .renameProject("/a"))
        model.modal = nil
        await model.kill(model.sessions[0].name)
    }

    @MainActor
    func testPromptEventsAndAnswer() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // A shell session that renders a numbered menu and then echoes input.
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.promptsByName["menu"] == ["yes", "no"]
        }
        await model.select("menu")
        model.apply(.answerPrompt(2))
        _ = await eventually {
            let bf = daemon.registry.backfill(name: "menu", since: 0)
            return bf.map { String(decoding: $0.bytes, as: UTF8.self).contains("2") } ?? false
        }
        daemon.registry.kill(name: "menu")
        _ = await eventually { model.sessions.isEmpty }
        XCTAssertNil(model.promptsByName["menu"], "kill clears the prompt")
    }

    @MainActor
    func testOpenRecentShowsModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openRecent)
        XCTAssertEqual(model.modal, .recent)
    }

}
