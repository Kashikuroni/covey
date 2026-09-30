import XCTest
@testable import covey

@MainActor
final class ReviewKeyRouterTests: XCTestCase {
    private func route(_ characters: String, command: Bool = false, control: Bool = false,
                       escape: Bool = false, context: ReviewKeyContext = ReviewKeyContext()) -> ReviewKeyAction? {
        ReviewKeyRouter.route(ReviewKeyEvent(characters: characters, isEscape: escape,
                                             command: command, control: control), context: context)
    }

    func testPlainKeysMapToActions() {
        let table: [(String, ReviewKeyAction)] = [
            ("j", .nextFile), ("k", .previousFile), ("]", .nextHunk), ("[", .previousHunk),
            ("i", .nextIssue), ("I", .previousIssue), ("u", .nextUnreviewed), ("r", .toggleReviewed),
            ("e", .toggleFullFile), ("c", .comment), ("f", .fit), ("0", .zoomReset),
            ("=", .zoomIn), ("+", .zoomIn), ("-", .zoomOut), ("1", .focusTree), ("2", .focusDiff),
            ("3", .focusCard), ("?", .showKeys), ("J", .nextFile), ("R", .toggleReviewed),
        ]
        for (key, action) in table {
            XCTAssertEqual(route(key), action, key)
        }
        XCTAssertNil(route("x"))
    }

    func testTextInputSwallowsEverythingButEscape() {
        let typing = ReviewKeyContext(textInputFocused: true)
        for key in ["j", "k", "r", "e", "c", "?", "1"] {
            XCTAssertNil(route(key, context: typing), key)
        }
        XCTAssertEqual(route("", escape: true, context: typing), .escape)
    }

    func testOpenModalOnlyTakesEscape() {
        let modal = ReviewKeyContext(modalOpen: true)
        XCTAssertNil(route("j", context: modal))
        XCTAssertEqual(route("", escape: true, context: modal), .escape)
    }

    func testCommandWClosesTheWindow() {
        XCTAssertEqual(route("w", command: true), .closeWindow)
        XCTAssertEqual(route("w", command: true, context: ReviewKeyContext(textInputFocused: true)), .closeWindow)
        XCTAssertNil(route("j", command: true))
        XCTAssertNil(route("j", control: true))
    }

    func testRussianLayoutRoutesLikeLatin() {
        let table: [(String, ReviewKeyAction)] = [
            ("о", .nextFile), ("л", .previousFile), ("к", .toggleReviewed), ("у", .toggleFullFile),
            ("с", .comment), ("г", .nextUnreviewed), ("а", .fit), ("ш", .nextIssue),
            ("Ш", .previousIssue), ("ъ", .nextHunk), ("х", .previousHunk),
        ]
        for (key, action) in table {
            XCTAssertEqual(route(key), action, key)
        }
        XCTAssertEqual(route("ц", command: true), .closeWindow)
        XCTAssertNil(route("о", context: ReviewKeyContext(textInputFocused: true)))
        XCTAssertNil(route("ц"))
    }

    func testHelpListsEveryShortcutOnce() {
        XCTAssertEqual(ReviewKeyRouter.help.count, 15)
        XCTAssertEqual(Set(ReviewKeyRouter.help.map(\.label)).count, 15)
    }

    func testPerformReachesTheModel() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        model.setCanvasViewport(CGSize(width: 800, height: 600))
        await model.perform(.nextFile)
        XCTAssertEqual(model.selectedPath, "a.swift")
        await model.perform(.showKeys)
        XCTAssertTrue(model.keysOverlayOpen)
        let zoom = model.canvas.zoom
        await model.perform(.zoomOut)
        XCTAssertLessThan(model.canvas.zoom, zoom)
        await model.perform(.escape)
        XCTAssertFalse(model.keysOverlayOpen)
    }

    func testDiffKeysReopenThePanelAfterEscape() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 1, "x")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        XCTAssertTrue(model.diffOpen)
        for action in [ReviewKeyAction.nextHunk, .previousHunk, .comment] {
            await model.escape()
            XCTAssertFalse(model.diffOpen, "Esc closes the panel before \(action)")
            await model.perform(action)
            XCTAssertTrue(model.diffOpen, "\(action) reopens the panel")
        }
        XCTAssertNotNil(model.composer, "C after Esc opens a composer in the visible panel")
        // Nothing selected: nothing to reopen.
        await model.select(nil)
        model.diffOpen = false
        await model.perform(.nextHunk)
        XCTAssertFalse(model.diffOpen)
    }
}
