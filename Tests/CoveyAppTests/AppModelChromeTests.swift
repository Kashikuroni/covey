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
    func testTransientToastAutoDismisses() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.toastDismissDelay = .milliseconds(30)
        model.showToast("project removed")
        XCTAssertEqual(model.toast, "project removed")
        let cleared = await eventually { model.toast == nil }
        XCTAssertTrue(cleared, "transient toast should auto-dismiss, not hang")
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
    func testOpenProjectNoteEntersInspectorNoteZone() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        model.apply(.openProjectNote)
        XCTAssertEqual(model.toast, "no project")

        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.openProjectNote)
        XCTAssertTrue(model.showInspector, "opening the note reveals the inspector")
        XCTAssertEqual(model.inspectorTab, .note)
        XCTAssertEqual(model.focus, .inspector)
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
    func testCreateIssueOpensInspectorIssueTab() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "no project")

        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "not a git repo")

        daemon.gitMonitor.onGitChanged?("agent", GitInfo(branch: "main", added: 0, removed: 0))
        _ = await eventually { model.sessions.first?.git != nil }
        let tickBefore = model.issueFocusTick
        model.apply(.createIssue)
        XCTAssertNil(model.modal)
        XCTAssertTrue(model.showInspector)
        XCTAssertEqual(model.inspectorTab, .issue)
        XCTAssertEqual(model.focus, .inspector)
        // The tick bump is deferred by one runloop turn (see AppModel's
        // .createIssue case) so a fresh IssuePane mount still observes an
        // .onChange fire — await it instead of asserting synchronously.
        let bumped = await eventually { model.issueFocusTick == tickBefore + 1 }
        XCTAssertTrue(bumped)

        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testOpenIssueListGuards() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.apply(.openIssueList)
        XCTAssertEqual(model.toast, "no session")   // guard fires, nothing opens
        XCTAssertNotEqual(model.focus, .inspector)
    }

    @MainActor
    func testNewSessionFromIssueWithoutSessionIsNoop() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newSessionFromIssue(number: 5, title: "t")
        XCTAssertNil(model.modal)
        XCTAssertNil(model.newSessionPrefillName)
    }

    @MainActor
    func testInspectorTabsSplitAndWindowToggles() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        XCTAssertEqual(model.inspectorTab, .note)
        model.apply(.inspectorPaneSwap)
        XCTAssertEqual(model.inspectorTab, .issue, "pane swap flips the active pane")
        model.apply(.inspectorPaneSwap)
        XCTAssertEqual(model.inspectorTab, .note)
        model.selectInspectorTab(.issue)
        XCTAssertEqual(model.inspectorTab, .issue)

        XCTAssertFalse(model.inspectorSplit)
        model.apply(.inspectorSplitToggle)
        XCTAssertTrue(model.inspectorSplit)

        let sessionsShown = model.showSessions
        model.apply(.toggleSessionsPanel)
        XCTAssertEqual(model.showSessions, !sessionsShown)
        let footerShown = model.showFooter
        model.apply(.toggleFooterPanel)
        XCTAssertEqual(model.showFooter, !footerShown)
        let headerShown = model.showHeader
        model.apply(.toggleHeaderPanel)
        XCTAssertEqual(model.showHeader, !headerShown)

        // Hiding the inspector while focused inside returns to sessions.
        model.setShowInspector(true)
        model.setFocus(.inspector)
        model.apply(.toggleInspectorPanel)
        XCTAssertFalse(model.showInspector)
        XCTAssertEqual(model.focus, .sessions)
    }

    @MainActor
    func testCycleFocusWalksInspectorTabsAsZones() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        model.setShowInspector(true)

        model.setFocus(.sessions)
        model.apply(.cycleFocus(forward: true))   // -> agent pane
        XCTAssertEqual(model.focus, .terminal)
        model.apply(.cycleFocus(forward: true))   // -> inspector, note zone
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.inspectorTab, .note)
        let tickBefore = model.issueFocusTick
        model.apply(.cycleFocus(forward: true))   // -> inspector, issue zone
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.inspectorTab, .issue)
        // Deferred one runloop turn (selectInspectorTab) — await it.
        let bumped = await eventually { model.issueFocusTick == tickBefore + 1 }
        XCTAssertTrue(bumped, "issue zone always lands in the form")
        model.apply(.cycleFocus(forward: true))   // wrap -> sessions
        XCTAssertEqual(model.focus, .sessions)
        model.apply(.cycleFocus(forward: false))  // back -> issue zone
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.inspectorTab, .issue)

        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testIssueDraftPerProjectRoot() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertEqual(model.issueDraft(forRoot: "/repo"), IssueDraft())
        model.setIssueDraft(IssueDraft(title: "t", body: "b", assignMe: true),
                            forRoot: "/repo")
        XCTAssertEqual(model.issueDraft(forRoot: "/repo").title, "t")
        model.clearIssueDraft(forRoot: "/repo")
        XCTAssertEqual(model.issueDraft(forRoot: "/repo"), IssueDraft())
    }

    @MainActor
    func testOpenRecentShowsModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openRecent)
        XCTAssertEqual(model.modal, .recent)
    }

    // A sheet dismissal steals the terminal's first responder: closing any
    // modal while the terminal zone owns the keyboard must re-focus it.
    @MainActor
    func testModalDismissRefocusesTerminalPane() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }

        var commands: [AppModel.TerminalCommand] = []
        model.setTerminalCommandHandler(for: "agent") { commands.append($0) }
        await model.select("agent")
        model.focusPane("agent")
        commands = []

        model.modal = .recent
        model.modal = nil
        _ = await eventually { commands.contains(.focus) }
        XCTAssertTrue(commands.contains(.focus), "dismiss must hand the keyboard back")

        // Not in the terminal zone -> no spurious focus grab.
        model.setFocus(.sessions)
        commands = []
        model.modal = .recent
        model.modal = nil
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(commands.contains(.focus))

        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testToggleThemeWithNoAgentsJustFlips() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let before = model.themeRaw
        model.apply(.toggleTheme)
        XCTAssertNotEqual(model.themeRaw, before)
        XCTAssertNil(model.modal)
        XCTAssertNil(model.toast)
    }

    @MainActor
    func testToggleThemeBusyClaudeShowsToast() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // No monitor tick -> no status -> the agent counts as busy.
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        model.apply(.toggleTheme)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast,
                       "1 agent(s) keep old theme — restart when idle (space s u)")
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testToggleThemeIdleClaudeOpensModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["agent"] == .idle
        }
        model.apply(.toggleTheme)
        XCTAssertEqual(model.modal, .themeRestart)
        XCTAssertNil(model.toast)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testToggleThemeIdleShellDoesNothing() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "shell")
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["shell"] == .idle
        }
        model.apply(.toggleTheme)
        XCTAssertNil(model.modal, "shells recolor live via installColors")
        XCTAssertNil(model.toast)
        daemon.registry.kill(name: "shell")
    }

    @MainActor
    func testRestartIdleClaudeSkipsBusy() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // Idle: prints a spawn marker, then sits quiet. Busy: renders a
        // numbered menu -> .waiting.
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "claude",
            argv: ["/bin/sh", "-c", "echo spawned-$$; exec cat"], name: "idler")
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "claude",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "busy")
        _ = await eventually { model.sessions.count == 2 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["idler"] == .idle
                && model.statusByName["busy"] == .waiting
        }
        let errors = await model.restartIdleClaude()
        XCTAssertEqual(errors, [])
        // The respawned /bin/sh prints a second marker onto the same screen.
        _ = await eventually {
            let text = daemon.registry.snapshotScreens()["idler"] ?? ""
            return text.components(separatedBy: "spawned-").count - 1 == 2
        }
        let markers = (daemon.registry.snapshotScreens()["idler"] ?? "")
            .components(separatedBy: "spawned-").count - 1
        XCTAssertEqual(markers, 2, "idle agent must have respawned")
        XCTAssertNotNil(daemon.registry.get(name: "busy"),
                        "busy agent must not be restarted")
        daemon.registry.kill(name: "idler")
        daemon.registry.kill(name: "busy")
    }


    @MainActor
    func testFocusZoneGuards() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.focusZone(.agent)
        XCTAssertEqual(model.toast, "no session")
        model.focusZone(.note)
        XCTAssertEqual(model.toast, "inspector hidden — space u i")
        model.focusZone(.issues)
        XCTAssertEqual(model.toast, "inspector hidden — space u i")
        model.focusZone(.terminalSplit)
        XCTAssertEqual(model.toast, "no split — space t v / h")
        XCTAssertNotEqual(model.focus, .inspector)   // guards never move focus
    }

    @MainActor
    func testFocusZoneSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.focusZone(.session)
        XCTAssertEqual(model.focus, .sessions)
    }

    @MainActor
    func testUsagePlacementCyclesAndClosesLeader() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertEqual(model.usagePlacement, .right)

        model.apply(.openLeader)
        model.apply(.leaderDescend(.ui))
        model.apply(.cycleUsagePlacement)
        XCTAssertEqual(model.usagePlacement, .left)
        XCTAssertEqual(model.inputMode, .normal)

        model.apply(.cycleUsagePlacement)
        XCTAssertEqual(model.usagePlacement, .center)
        model.apply(.cycleUsagePlacement)
        XCTAssertEqual(model.usagePlacement, .right)
    }

    @MainActor
    func testUsagePlacementPersistsAndUnknownFallsBackToRight() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-placement-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: store)
        await model.start()
        model.apply(.cycleUsagePlacement)
        store.flush()

        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let reloaded = AppModel(
            client: client2,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: path, debounce: 0.05))
        await reloaded.start()
        XCTAssertEqual(reloaded.usagePlacement, .left)

        let invalidStore = StateStore(path: path, debounce: 0.05)
        invalidStore.save(PersistedState(usagePlacement: "diagonal"))
        invalidStore.flush()
        let client3 = IPCClient(path: daemon.path); try client3.connect()
        let invalid = AppModel(
            client: client3,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: path, debounce: 0.05))
        await invalid.start()
        XCTAssertEqual(invalid.usagePlacement, .right)
    }
}
