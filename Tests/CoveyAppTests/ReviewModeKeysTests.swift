import XCTest
@testable import covey

final class ReviewModeKeysTests: XCTestCase {
    private func decide(_ characters: String, escape: Bool = false, command: Bool = false,
                        _ configure: (inout ReviewModeKeyInput) -> Void = { _ in }) -> ReviewModeKeyDecision {
        var input = ReviewModeKeyInput(key: ReviewKeyEvent(characters: characters, isEscape: escape,
                                                           command: command))
        configure(&input)
        return ReviewModeKeys.decide(input)
    }

    func testPlainKeysBecomeReviewActions() {
        XCTAssertEqual(decide("j"), .perform(.nextFile))
        XCTAssertEqual(decide("?"), .perform(.showKeys))
        XCTAssertEqual(decide("", escape: true), .perform(.escape))
        XCTAssertEqual(decide("x"), .pass)
    }

    func testCommandWLeavesReviewOnAnyLayout() {
        XCTAssertEqual(decide("w", command: true) { $0.isCommandW = true }, .perform(.closeReview))
        // Russian layout: the W key types "ц"; the router latinizes it.
        XCTAssertEqual(decide("ц", command: true), .perform(.closeReview))
        XCTAssertEqual(decide("p", command: true), .pass, "other ⌘-keys belong to the menus")
    }

    func testCommandWIsSwallowedWhileThePaletteOrASheetIsUp() {
        XCTAssertEqual(decide("w", command: true) { $0.isCommandW = true; $0.paletteOpen = true }, .swallow)
        XCTAssertEqual(decide("w", command: true) { $0.isCommandW = true; $0.sheetOpen = true }, .swallow)
        XCTAssertEqual(decide("ц", command: true) { $0.paletteOpen = true }, .pass)
    }

    func testEscapeInASingleLineFieldOnlyEndsEditing() {
        XCTAssertEqual(decide("", escape: true) { $0.textInputFocused = true; $0.fieldEditorFocused = true },
                       .endEditing)
        // The composer is a multi-line text view: Esc still unwinds it.
        XCTAssertEqual(decide("", escape: true) { $0.textInputFocused = true }, .perform(.escape))
    }

    func testTypingInAFieldPassesThrough() {
        for key in ["j", "r", "?", "c"] {
            XCTAssertEqual(decide(key) { $0.textInputFocused = true }, .pass, key)
        }
    }

    func testHeldTogglesDoNotRepeatButNavigationDoes() {
        XCTAssertEqual(decide("r") { $0.isRepeat = true }, .swallow)
        XCTAssertEqual(decide("e") { $0.isRepeat = true }, .swallow)
        XCTAssertEqual(decide("?") { $0.isRepeat = true }, .swallow)
        XCTAssertEqual(decide("l") { $0.isRepeat = true }, .swallow, "a held L must not flicker the links")
        XCTAssertEqual(decide("l"), .perform(.toggleLinks))
        XCTAssertEqual(decide("j") { $0.isRepeat = true }, .perform(.nextFile))
    }

    func testThePaletteAndSheetsOwnTheKeyboard() {
        XCTAssertEqual(decide("j") { $0.paletteOpen = true }, .pass)
        XCTAssertEqual(decide("", escape: true) { $0.paletteOpen = true }, .pass)
        XCTAssertEqual(decide("j") { $0.sheetOpen = true }, .pass)
    }

    func testAMainWindowOverlayOwnsTheKeys() {
        XCTAssertEqual(decide("j") { $0.appOverlayOpen = true }, .overlay)
        XCTAssertEqual(decide("", escape: true) { $0.appOverlayOpen = true }, .overlay)
    }

    /// Review leaves the focus where it was: often on the hidden terminal.
    private func overlay(_ mode: InputMode, vim: Bool, focus: AppModel.Focus = .terminal,
                         _ key: KeyInput) -> KeyAction? {
        ReviewModeKeys.overlayAction(key, context: KeyRouter.Context(mode: mode, focus: focus,
                                                                     vimMode: vim, sheetOpen: false))
    }

    func testTheOverlaysOwnKeysAct() {
        XCTAssertEqual(overlay(.limits, vim: true, KeyInput(char: "j")), .limitsSelectNext)
        XCTAssertEqual(overlay(.limits, vim: true, KeyInput(char: "k")), .limitsSelectPrev)
        XCTAssertEqual(overlay(.limits, vim: true, KeyInput(char: "h")), .limitsDisableSelected)
        XCTAssertEqual(overlay(.limits, vim: true, KeyInput(char: "l")), .limitsEnableSelected)
        XCTAssertEqual(overlay(.limits, vim: true, KeyInput(char: "q")), .closeOverlay)
        XCTAssertEqual(overlay(.help, vim: true, KeyInput(char: "x")), .closeOverlay)
    }

    func testEscapeClosesTheOverlayWhateverTheVimMode() {
        for mode in [InputMode.limits, .help, .selectSession] {
            for vim in [true, false] {
                XCTAssertEqual(overlay(mode, vim: vim, KeyInput(special: .escape)), .closeOverlay,
                               "\(mode) vim \(vim)")
            }
        }
    }

    /// The sessions router would send these to the hidden agent (⇧Tab,
    /// ⇧Enter) or act on the hidden workspace (⌃q, ⌃h/⌃l, ⌃\, s-mode digits).
    func testNothingReachesTheHiddenSessions() {
        let chords = [KeyInput(isShift: true, special: .tab), KeyInput(isShift: true, special: .enter),
                      KeyInput(char: "q", isControl: true), KeyInput(char: "h", isControl: true),
                      KeyInput(char: "l", isControl: true), KeyInput(char: "\\", isControl: true)]
        for key in chords {
            XCTAssertNil(overlay(.limits, vim: false, key), "\(key)")
            XCTAssertNil(overlay(.help, vim: false, key), "\(key)")
        }
        XCTAssertNil(overlay(.selectSession, vim: true, focus: .sessions, KeyInput(char: "2")),
                     "no session switch behind Review")
    }

    func testAnOpenReviewModalOnlyTakesEscape() {
        XCTAssertEqual(decide("j") { $0.reviewModalOpen = true }, .pass)
        XCTAssertEqual(decide("", escape: true) { $0.reviewModalOpen = true }, .perform(.escape))
    }
}
