import XCTest
@testable import covey

final class StatusBarTests: XCTestCase {
    func testReviewFooterPointsBackToTheSessions() {
        let hints = Dictionary(uniqueKeysWithValues: reviewStatusBarHints)
        XCTAssertEqual(hints["⌘W"], "sessions")
        XCTAssertEqual(hints["?"], "keys")
        XCTAssertEqual(hints["⌘P"], "commands")
    }

    func testStandardFooterShowsPanelShortcut() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .list
        ))

        XCTAssertEqual(hints["ctrl + 1...5"], "Panels")
    }

    func testComposerFooterShowsEscapeToList() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .composer,
            browserScreen: .list
        ))

        XCTAssertEqual(hints["esc"], "list")
    }

    func testDetailFooterShowsEscapeToList() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .detail(6)
        ))

        XCTAssertEqual(hints["esc"], "list")
    }

    func testDetailFooterShowsOpenAndJumpForLiveSession() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .detail(6),
            sessionState: .live
        ))

        XCTAssertEqual(hints["s"], "open")
        XCTAssertEqual(hints["g"], "session ↗")
    }

    func testDetailFooterShowsOpenWithoutJumpForRecentSession() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .detail(6),
            sessionState: .recent
        ))

        XCTAssertEqual(hints["s"], "open")
        XCTAssertNil(hints["g"])
    }

    func testDetailFooterShowsCreateWithoutJumpWhenNoSessionExists() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .detail(6),
            sessionState: .none
        ))

        XCTAssertEqual(hints["s"], "session")
        XCTAssertNil(hints["g"])
    }

    func testEditFooterShowsSaveAndCancel() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .edit(6)
        ))

        XCTAssertEqual(hints["enter"], "save")
        XCTAssertEqual(hints["esc"], "cancel")
    }

    func testListFooterShowsListActions() {
        let hints = Dictionary(uniqueKeysWithValues: issueStatusBarHintPairs(
            issueScreen: .browser,
            browserScreen: .list
        ))

        XCTAssertEqual(hints["enter"], "view")
        XCTAssertEqual(hints["n"], "new")
        XCTAssertEqual(hints["r"], "refresh")
        XCTAssertEqual(hints["/"], "search")
    }
}
