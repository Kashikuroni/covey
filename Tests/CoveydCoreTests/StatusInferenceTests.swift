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
