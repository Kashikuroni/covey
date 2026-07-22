import XCTest
@testable import covey

final class CodexUsageTests: XCTestCase {
    func testWindowLabelFromMinutes() {
        XCTAssertEqual(codexWindowLabel(minutes: 300), "5h")
        XCTAssertEqual(codexWindowLabel(minutes: 10080), "7d")
        XCTAssertEqual(codexWindowLabel(minutes: 60), "1h")
        XCTAssertEqual(codexWindowLabel(minutes: 90), "90m")
        XCTAssertEqual(codexWindowLabel(minutes: 4320), "3d")
    }

    func testPlanLabel() {
        XCTAssertEqual(codexPlanLabel("plus"), "Plus")
        XCTAssertEqual(codexPlanLabel("pro"), "Pro")
        XCTAssertEqual(codexPlanLabel("team"), "Team")
        XCTAssertEqual(codexPlanLabel("enterprise-xl"), "Enterprise-xl")
        XCTAssertNil(codexPlanLabel(nil))
        XCTAssertNil(codexPlanLabel(""))
    }

    func testParseAccountChatGPT() {
        let json: [String: Any] = ["account": ["type": "chatgpt", "planType": "plus"]]
        XCTAssertEqual(parseCodexAccount(json), CodexAccount(type: "chatgpt", planType: "plus"))
    }

    func testParseAccountSnakeCaseAndApiKey() {
        let json: [String: Any] = ["account": ["type": "apiKey", "plan_type": NSNull()]]
        XCTAssertEqual(parseCodexAccount(json), CodexAccount(type: "apiKey", planType: nil))
        XCTAssertNil(parseCodexAccount(["nope": 1]))
    }

    func testParseRateLimitsPrimarySecondary() {
        let json: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 12.0, "windowDurationMins": 300, "resetsAt": 1_008_000],
            "secondary": ["used_percent": 40.0, "window_duration_mins": 10080, "resets_at": 1_600_000],
        ]]
        let snap = parseCodexRateLimits(json)
        XCTAssertEqual(snap?.primary, LabeledWindow(label: "5h",
            window: UsageWindow(utilization: 12, resetUnix: 1_008_000)))
        XCTAssertEqual(snap?.secondary, LabeledWindow(label: "7d",
            window: UsageWindow(utilization: 40, resetUnix: 1_600_000)))
        XCTAssertEqual(snap?.windows.count, 2)
    }

    func testParseRateLimitsBucketWithoutWrapper() {
        let json: [String: Any] = ["primary": ["usedPercent": 5.0, "windowDurationMins": 300]]
        let snap = parseCodexRateLimits(json)
        XCTAssertEqual(snap?.primary?.label, "5h")
        XCTAssertNil(snap?.primary?.window.resetUnix)   // resetsAt absent
        XCTAssertNil(snap?.secondary)
    }

    func testParseRateLimitsEmptyIsNil() {
        XCTAssertNil(parseCodexRateLimits(["rateLimits": [String: Any]()]))
        XCTAssertNil(parseCodexRateLimits([String: Any]()))
    }

    func testMergePartialUpdateKeepsOtherWindow() {
        let base = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 10, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 40, resetUnix: 2)))
        let update = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 85, resetUnix: 3)),
            secondary: nil)
        let merged = mergeCodex(into: base, update: update)
        XCTAssertEqual(merged.primary?.window.utilization, 85)
        XCTAssertEqual(merged.secondary?.window.utilization, 40)  // untouched
    }

    func testMergeIntoNilReturnsUpdate() {
        let update = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 7, resetUnix: nil)),
            secondary: nil)
        XCTAssertEqual(mergeCodex(into: nil, update: update), update)
    }
}
