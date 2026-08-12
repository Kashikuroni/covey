import XCTest
@testable import covey

final class KeyRouterTests: XCTestCase {
    private func ctx(mode: InputMode = .normal,
                     focus: AppModel.Focus = .sessions,
                     vim: Bool = true,
                     sheet: Bool = false) -> KeyRouter.Context {
        .init(mode: mode, focus: focus, vimMode: vim, sheetOpen: sheet)
    }
    private func key(_ c: Character, ctrl: Bool = false) -> KeyInput {
        .init(char: c, isControl: ctrl)
    }
    private func special(_ s: Special, ctrl: Bool = false) -> KeyInput {
        .init(char: nil, isControl: ctrl, special: s)
    }

    func testLatinize() {
        XCTAssertEqual(latinize("о"), "j")
        XCTAssertEqual(latinize("л"), "k")
        XCTAssertEqual(latinize("П"), "G")
        XCTAssertEqual(latinize("a"), "a")
        XCTAssertEqual(latinize("1"), "1")
    }

    func testNormalModeBindings() {
        let cases: [(KeyInput, KeyAction)] = [
            (key("j"), .selectNext), (key("k"), .selectPrev),
            (special(.down), .selectNext), (special(.up), .selectPrev),
            (key("g"), .selectFirst), (key("G"), .scrollTerminalToBottom),
            (special(.end), .scrollTerminalToBottom),
            (special(.enter), .enterTerminal), (key("o"), .enterTerminal),
            (key("n"), .newSession(prefillDir: false)),
            (key("N"), .newSession(prefillDir: true)),
            (key("d"), .killSelected),
            (key("/"), .startFilter),
            (key("s"), .enterSelectMode),
            (key(" "), .openLeader),
            (key("K"), .moveSelected(up: true)), (key("J"), .moveSelected(up: false)),
            (key("["), .resizeSplit(-3)), (key("]"), .resizeSplit(3)),
            (key("{"), .resizeSplit(-8)), (key("}"), .resizeSplit(8)),
            (special(.left, ctrl: true), .resizeSplit(-8)),
            (special(.right, ctrl: true), .resizeSplit(8)),
            (key("k", ctrl: true), .scrollTerminalPage(up: true)),
            (key("j", ctrl: true), .scrollTerminalPage(up: false)),
            (key("l", ctrl: true), .cycleFocus(forward: true)),
            (key("h", ctrl: true), .cycleFocus(forward: false)),
            (special(.pageUp), .scrollTerminalPage(up: true)),
            (special(.pageDown), .scrollTerminalPage(up: false)),
            (key("?"), .showHelp),
        ]
        for (input, want) in cases {
            XCTAssertEqual(KeyRouter.route(input, context: ctx()), want, "\(input)")
        }
        XCTAssertNil(KeyRouter.route(key("z"), context: ctx()), "unbound key ignored")
    }

    func testCyrillicChordsWork() {
        XCTAssertEqual(KeyRouter.route(key("о"), context: ctx()), .selectNext)
        XCTAssertEqual(KeyRouter.route(key("л"), context: ctx()), .selectPrev)
    }

    func testTerminalFocusOnlyCtrlQ() {
        let terminal = ctx(focus: .terminal)
        XCTAssertEqual(KeyRouter.route(key("q", ctrl: true), context: terminal), .exitTerminal)
        XCTAssertEqual(KeyRouter.route(.init(char: nil, isShift: true, special: .tab),
                                       context: terminal), .sendShiftTab,
                       "shift-tab must reach the agent, not AppKit focus traversal")
        XCTAssertEqual(KeyRouter.route(.init(char: nil, isShift: true, special: .enter),
                                       context: terminal), .sendShiftEnter,
                       "shift-enter must break the line, not submit like a bare CR")
        XCTAssertNil(KeyRouter.route(special(.enter), context: terminal),
                     "plain enter stays the agent's own key")
        XCTAssertNil(KeyRouter.route(key("j"), context: terminal))
        XCTAssertNil(KeyRouter.route(key(" "), context: terminal))
        // ⌃Q from the list side does nothing.
        XCTAssertNil(KeyRouter.route(key("q", ctrl: true), context: ctx()))
    }

    func testSheetAndVimOffSwallowEverything() {
        XCTAssertNil(KeyRouter.route(key("j"), context: ctx(sheet: true)))
        XCTAssertNil(KeyRouter.route(key("q", ctrl: true), context: ctx(focus: .terminal, sheet: true)))
        XCTAssertNil(KeyRouter.route(key("j"), context: ctx(vim: false)))
    }

    func testLeaderTree() {
        let root = ctx(mode: .leader(.root))
        XCTAssertEqual(KeyRouter.route(key("g"), context: root), .leaderDescend(.git))
        XCTAssertEqual(KeyRouter.route(key("s"), context: root), .leaderDescend(.session))
        XCTAssertEqual(KeyRouter.route(special(.escape), context: root), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(key("x"), context: root), .closeOverlay, "unbound closes")
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("r"), context: session), .renameSelected)
        XCTAssertEqual(KeyRouter.route(special(.backspace), context: session), .leaderBack)
        XCTAssertEqual(KeyRouter.route(key("v"), context: session), .closeOverlay, "later command closes")
        let git = ctx(mode: .leader(.git))
        XCTAssertEqual(KeyRouter.route(key("p"), context: git), .promoteSelected)
        XCTAssertEqual(KeyRouter.route(key("b"), context: git), .deleteBranchSelected)
        XCTAssertEqual(KeyRouter.route(key("c"), context: git), .cleanupBranches)
        XCTAssertEqual(KeyRouter.route(key("i"), context: git), .createIssue)
        XCTAssertEqual(KeyRouter.route(key("u"), context: session), .restartSelected)
        XCTAssertEqual(KeyRouter.route(key("U"), context: session), .restartAllPrompt)
        XCTAssertEqual(KeyRouter.route(key("t"), context: ctx(mode: .leader(.ui))),
                       .toggleTheme)
        XCTAssertEqual(KeyRouter.route(key("a"), context: ctx(mode: .leader(.ui))),
                       .toggleTracePanel)
        XCTAssertEqual(KeyRouter.route(key("r"), context: git), .returnToRoot)
    }

    func testRootMenuShowsEveryDescendKey() {
        // The which-key panel must list every root key that opens a submenu —
        // a chord that routes but has no visible row is invisible to the user.
        let root = ctx(mode: .leader(.root))
        let rowKeys = Set(LeaderMenu.root.rows.map(\.key))
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            guard case .leaderDescend = KeyRouter.route(key(ch), context: root) else { continue }
            XCTAssertTrue(rowKeys.contains(String(ch)),
                          "space \(ch) descends into a submenu but has no row in the panel")
        }
    }

    func testSelectSessionMode() {
        let sel = ctx(mode: .selectSession)
        XCTAssertEqual(KeyRouter.route(key("1"), context: sel), .selectByNumber(1))
        XCTAssertEqual(KeyRouter.route(key("9"), context: sel), .selectByNumber(9))
        XCTAssertEqual(KeyRouter.route(special(.escape), context: sel), .closeOverlay)
        XCTAssertNil(KeyRouter.route(key("x"), context: sel), "other keys ignored, mode stays")
    }

    func testHelpClosesOnAnyKey() {
        let help = ctx(mode: .help)
        XCTAssertEqual(KeyRouter.route(key("x"), context: help), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(special(.enter), context: help), .closeOverlay)
    }

    func testRemovedNoteKeysAreUnbound() {
        XCTAssertNil(KeyRouter.route(key("t"), context: ctx()))
        XCTAssertNil(KeyRouter.route(key("T"), context: ctx()))
        XCTAssertNil(KeyRouter.route(key("е"), context: ctx()), "ЙЦУКЕН t")
    }

    func testLeaderSessionRenameProject() {
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("R"), context: session), .renameProject)
    }

    func testProjectLeaderGroup() {
        XCTAssertEqual(KeyRouter.route(key("p"), context: ctx(mode: .leader(.root))),
                       .leaderDescend(.project))
        let p = ctx(mode: .leader(.project))
        XCTAssertEqual(KeyRouter.route(key("a"), context: p), .addProject)
        XCTAssertEqual(KeyRouter.route(key("d"), context: p), .removeProject)
        XCTAssertEqual(KeyRouter.route(key("z"), context: p), .closeOverlay,
                       "unbound key closes the leader")
    }

    func testTerminalSplitChords() {
        XCTAssertEqual(KeyRouter.route(key("t"), context: ctx(mode: .leader(.root))),
                       .leaderDescend(.terminal))
        let leaderT = ctx(mode: .leader(.terminal))
        XCTAssertEqual(KeyRouter.route(key("v"), context: leaderT), .splitVertical)
        XCTAssertEqual(KeyRouter.route(key("h"), context: leaderT), .splitHorizontal)
        XCTAssertEqual(KeyRouter.route(key("x"), context: leaderT), .splitClose)
        // ⌃\ toggles pane focus from both the list and the live terminal.
        XCTAssertEqual(KeyRouter.route(key("\\", ctrl: true), context: ctx()),
                       .splitFocusToggle)
        XCTAssertEqual(KeyRouter.route(key("\\", ctrl: true), context: ctx(focus: .terminal)),
                       .splitFocusToggle)
        // ⌃h/⌃l walk the focus zones — from the terminal too.
        XCTAssertEqual(KeyRouter.route(key("l", ctrl: true), context: ctx(focus: .terminal)),
                       .cycleFocus(forward: true))
        XCTAssertEqual(KeyRouter.route(key("h", ctrl: true), context: ctx(focus: .terminal)),
                       .cycleFocus(forward: false))
        // The inspector uses the same global focus cycle.
    }

    func testInspectorZoneChords() {
        let insp = ctx(focus: .inspector)
        // ⌃h/⌃l cycle the focus zones everywhere, including the inspector.
        XCTAssertEqual(KeyRouter.route(key("l", ctrl: true), context: insp),
                       .cycleFocus(forward: true))
        XCTAssertEqual(KeyRouter.route(key("h", ctrl: true), context: insp),
                       .cycleFocus(forward: false))
        XCTAssertNil(KeyRouter.route(key("j", ctrl: true), context: insp))
        XCTAssertNil(KeyRouter.route(key("k", ctrl: true), context: insp))
        // Outside the zone the old meanings stay.
        XCTAssertEqual(KeyRouter.route(key("l", ctrl: true), context: ctx()),
                       .cycleFocus(forward: true))
        XCTAssertEqual(KeyRouter.route(key("s"), context: ctx()), .enterSelectMode)
    }

    func testUiLeaderGroup() {
        XCTAssertEqual(KeyRouter.route(key("u"), context: ctx(mode: .leader(.root))),
                       .leaderDescend(.ui))
        let u = ctx(mode: .leader(.ui))
        XCTAssertEqual(KeyRouter.route(key("s"), context: u), .toggleSessionsPanel)
        XCTAssertEqual(KeyRouter.route(key("i"), context: u), .toggleInspectorPanel)
        XCTAssertEqual(KeyRouter.route(key("f"), context: u), .toggleFooterPanel)
        XCTAssertEqual(KeyRouter.route(key("h"), context: u), .toggleHeaderPanel)
        XCTAssertEqual(KeyRouter.route(key("t"), context: u), .toggleTheme)
        XCTAssertEqual(KeyRouter.route(key("v"), context: u), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(key("l"), context: u), .cycleUsagePlacement)
        XCTAssertFalse(LeaderMenu.ui.rows.contains { $0.key == "v" })
        XCTAssertTrue(LeaderMenu.ui.rows.contains {
            $0.key == "l" && $0.label == "cycle limits / clock position" && $0.implemented
        })
        // The old app group is gone.
        XCTAssertEqual(KeyRouter.route(key("a"), context: ctx(mode: .leader(.root))),
                       .closeOverlay)
    }

    func testGitIssueChord() {
        XCTAssertEqual(KeyRouter.route(key("i"), context: ctx(mode: .leader(.git))),
                       .createIssue)
    }

    func testGitLeaderRoutesIssueList() {
        let ctx = KeyRouter.Context(mode: .leader(.git), focus: .sessions,
                                    vimMode: true, sheetOpen: false)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "l"), context: ctx),
                       .openIssueList)
    }

    func testRecentModalKey() {
        XCTAssertEqual(KeyRouter.route(key("r"), context: ctx()), .openRecent)
        // In the terminal the key belongs to the agent.
        XCTAssertNil(KeyRouter.route(key("r"), context: ctx(focus: .terminal)))
    }

    func testDigitsUnboundAndShiftTab() {
        // Answers feature removed: digits no longer answer a card prompt.
        XCTAssertNil(KeyRouter.route(key("1"), context: ctx()), "digits unbound in normal now")
        XCTAssertNil(KeyRouter.route(key("9"), context: ctx()))
        XCTAssertNil(KeyRouter.route(key("i"), context: ctx()), "no reply composer: terminal is live")
        XCTAssertEqual(KeyRouter.route(.init(char: nil, isShift: true, special: .tab),
                                       context: ctx()), .sendShiftTab)
        // plain tab still toggles tabs, select-mode digits still jump
        XCTAssertNil(KeyRouter.route(special(.tab), context: ctx()), "plain tab is unbound now")
        XCTAssertEqual(KeyRouter.route(key("2"), context: ctx(mode: .selectSession)),
                       .selectByNumber(2))
    }

    func testLimitsOverlayOpensFromRootAndClosesOnAnyKey() {
        XCTAssertEqual(KeyRouter.route(key("l"), context: ctx(mode: .leader(.root))),
                       .toggleLimitsOverlay)
        XCTAssertTrue(LeaderMenu.root.rows.contains { $0.key == "l" && $0.implemented },
                      "space l must be advertised in the which-key root panel")
        let limits = ctx(mode: .limits)
        XCTAssertEqual(KeyRouter.route(key("x"), context: limits), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(special(.escape), context: limits), .closeOverlay)
    }

    func testLimitsModeNavigationAndToggleKeys() {
        let limits = ctx(mode: .limits)
        XCTAssertEqual(KeyRouter.route(key("j"), context: limits), .limitsSelectNext)
        XCTAssertEqual(KeyRouter.route(key("k"), context: limits), .limitsSelectPrev)
        XCTAssertEqual(KeyRouter.route(key("h"), context: limits), .limitsDisableSelected)
        XCTAssertEqual(KeyRouter.route(key("l"), context: limits), .limitsEnableSelected)
        // Cyrillic JCUKEN keys at the same physical position work too (latinize).
        XCTAssertEqual(KeyRouter.route(key("о"), context: limits), .limitsSelectNext)
        XCTAssertEqual(KeyRouter.route(key("л"), context: limits), .limitsSelectPrev)
        XCTAssertEqual(KeyRouter.route(key("р"), context: limits), .limitsDisableSelected)
        XCTAssertEqual(KeyRouter.route(key("д"), context: limits), .limitsEnableSelected)
        // Anything else still closes the popover.
        XCTAssertEqual(KeyRouter.route(key("q"), context: limits), .closeOverlay)
    }
}
