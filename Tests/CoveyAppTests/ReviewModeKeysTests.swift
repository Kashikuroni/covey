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
        XCTAssertEqual(decide("j") { $0.isRepeat = true }, .perform(.nextFile))
    }

    func testThePaletteAndSheetsOwnTheKeyboard() {
        XCTAssertEqual(decide("j") { $0.paletteOpen = true }, .pass)
        XCTAssertEqual(decide("", escape: true) { $0.paletteOpen = true }, .pass)
        XCTAssertEqual(decide("j") { $0.sheetOpen = true }, .pass)
    }

    func testAMainWindowOverlayGoesToTheSessionsRouter() {
        XCTAssertEqual(decide("j") { $0.appOverlayOpen = true }, .sessions)
        XCTAssertEqual(decide("", escape: true) { $0.appOverlayOpen = true }, .sessions)
    }

    func testAnOpenReviewModalOnlyTakesEscape() {
        XCTAssertEqual(decide("j") { $0.reviewModalOpen = true }, .pass)
        XCTAssertEqual(decide("", escape: true) { $0.reviewModalOpen = true }, .perform(.escape))
    }
}
