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
            (special(.tab), .toggleTab),
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
        XCTAssertEqual(KeyRouter.route(key("a"), context: root), .leaderDescend(.app))
        XCTAssertEqual(KeyRouter.route(special(.escape), context: root), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(key("x"), context: root), .closeOverlay, "unbound closes")
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("r"), context: session), .renameSelected)
        XCTAssertEqual(KeyRouter.route(special(.backspace), context: session), .leaderBack)
        XCTAssertEqual(KeyRouter.route(key("v"), context: session), .closeOverlay, "later command closes")
        let git = ctx(mode: .leader(.git))
        XCTAssertEqual(KeyRouter.route(key("p"), context: git), .closeOverlay, "later command closes")
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

    func testNoteToggleKeysInNormalMode() {
        XCTAssertEqual(KeyRouter.route(key("t"), context: ctx()), .toggleSessionNote)
        XCTAssertEqual(KeyRouter.route(key("T"), context: ctx()), .toggleProjectNote)
        XCTAssertEqual(KeyRouter.route(key("е"), context: ctx()), .toggleSessionNote, "ЙЦУКЕН t")
    }

    func testNoteModeBindings() {
        let note = ctx(mode: .note)
        let cases: [(KeyInput, KeyAction)] = [
            (key("j"), .noteCursor(down: true)), (key("k"), .noteCursor(down: false)),
            (special(.down), .noteCursor(down: true)), (special(.up), .noteCursor(down: false)),
            (key(" "), .noteToggleTask),
            (key("V"), .noteVisual),
            (key("y"), .noteYank),
            (key("d"), .noteDelete),
            (key("e"), .noteEdit),
            (key("c"), .noteArmClear),
            (special(.tab), .noteDefocus),
            (special(.escape), .noteEscape),
        ]
        for (input, want) in cases {
            XCTAssertEqual(KeyRouter.route(input, context: note), want, "\(input)")
        }
        XCTAssertNil(KeyRouter.route(key("z"), context: note), "unbound ignored")
    }

    func testLeaderSessionRenameProject() {
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("R"), context: session), .renameProject)
    }
}
