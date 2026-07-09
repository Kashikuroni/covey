import XCTest
@testable import CoveydCore
import CoveyKit

final class StatusInferenceTests: XCTestCase {
    func testParsePromptDetectsNumberedMenu() {
        let content = "some output\n  1. yes\n  2. no\n  3. cancel\n"
        XCTAssertEqual(StatusInference.parsePrompt(content), ["yes", "no", "cancel"])
    }

    func testParsePromptIgnoresSingleOption() {
        XCTAssertEqual(StatusInference.parsePrompt("1. only one\n"), [])
    }

    func testParsePromptHandlesSelectionMarkers() {
        let content = "❯ 1. accept\n  2. reject\n"
        XCTAssertEqual(StatusInference.parsePrompt(content), ["accept", "reject"])
    }

    func testParsePromptTruncatesLabelsTo40Chars() {
        let long = String(repeating: "x", count: 60)
        let content = "1. \(long)\n2. b\n"
        XCTAssertEqual(StatusInference.parsePrompt(content).first?.count, 40)
    }

    func testParsePromptIgnoresMenuAboveLast20Lines() {
        let menu = "1. yes\n2. no\n"
        let padding = String(repeating: "line\n", count: 25)
        XCTAssertEqual(StatusInference.parsePrompt(menu + padding), [])
    }

    // Claude Code's AskUserQuestion box: the selected row hugs the cursor with
    // no space ("❯1.Python"), rows squish, descriptions interleave.
    func testParsePromptDetectsClaudeBoxWithTightCursor() {
        let content = """
        Какой стек предпочитаешь?

        ❯1.Python + FastAPI
             Быстрый async-бэкенд, привычный стек.
          2. Go + Chi
             Компилируемый, один бинарь.
        3.Rust+Axum
        ─────────────────────────
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        XCTAssertEqual(StatusInference.parsePrompt(content),
                       ["Python + FastAPI", "Go + Chi", "Rust+Axum"])
    }

    func testHasSelectionPromptViaFooterMarker() {
        // Options don't line up, but the footer marker still means "waiting".
        let content = "Question?\n weird · options\n↑/↓ to navigate\n"
        XCTAssertTrue(StatusInference.hasSelectionPrompt(content))
    }

    func testHasSelectionPromptViaOptions() {
        XCTAssertTrue(StatusInference.hasSelectionPrompt("1. a\n2. b\n"))
    }

    func testHasSelectionPromptFalseForPlainOutput() {
        XCTAssertFalse(StatusInference.hasSelectionPrompt("just output\nno prompt here"))
    }

    func testContentHashStableForSameInput() {
        XCTAssertEqual(StatusInference.contentHash("abc"), StatusInference.contentHash("abc"))
        XCTAssertNotEqual(StatusInference.contentHash("abc"), StatusInference.contentHash("abd"))
    }

    func testComputeStatusFirstObservationIsIdle() {
        XCTAssertEqual(StatusInference.computeStatus(prev: nil, current: 5), .idle)
    }

    func testComputeStatusChangeIsRunning() {
        XCTAssertEqual(StatusInference.computeStatus(prev: 1, current: 2), .running)
        XCTAssertEqual(StatusInference.computeStatus(prev: 2, current: 2), .idle)
    }

    func testIsWorkingDetectsMarker() {
        XCTAssertTrue(StatusInference.isWorking("… esc to interrupt …"))
        XCTAssertFalse(StatusInference.isWorking("idle prompt >"))
    }

    func testDeriveStatusPrecedence() {
        // prompt wins over everything
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "esc to interrupt", prevHash: 1, currentHash: 2, hasPrompt: true),
            .waiting
        )
        // working marker beats frame-diff
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "esc to interrupt", prevHash: 2, currentHash: 2, hasPrompt: false),
            .running
        )
        // fallback to frame-diff
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "quiet", prevHash: 1, currentHash: 2, hasPrompt: false),
            .running
        )
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "quiet", prevHash: 2, currentHash: 2, hasPrompt: false),
            .idle
        )
    }
}
