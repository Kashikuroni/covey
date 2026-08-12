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
            (special(.enter), .command(.focusAgent)), (key("o"), .command(.focusAgent)),
            (key("n"), .command(.newSession)),
            (key("N"), .command(.newSessionInCurrentProject)),
            (key("d"), .command(.killSession)),
            (key("/"), .command(.filterSessions)),
            (key("s"), .enterSelectMode),
            (key("K"), .command(.moveSessionUp)),
            (key("J"), .command(.moveSessionDown)),
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
            (key("?"), .command(.showKeyboardHelp)),
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

    func testTerminalSplitChords() {
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

    func testRecentModalKey() {
        XCTAssertEqual(KeyRouter.route(key("r"), context: ctx()), .command(.recentSessions))
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

    func testSpaceIsNoLongerAnAppBinding() {
        XCTAssertNil(KeyRouter.route(key(" "), context: ctx()))
        XCTAssertNil(KeyRouter.route(key(" "), context: ctx(focus: .terminal)))
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
