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

    func testParseRateLimitsByLimitIDKeepsEveryBucket() {
        let json: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "limitName": NSNull(),
                "planType": "prolite",
                "primary": ["usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1_700_000],
                "secondary": NSNull(),
                "rateLimitReachedType": NSNull(),
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "planType": "prolite",
                    "primary": ["usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1_700_000],
                    "secondary": NSNull(),
                    "rateLimitReachedType": NSNull(),
                ],
                "codex_bengalfox": [
                    "limitId": "codex_bengalfox",
                    "limitName": "GPT-5.3-Codex-Spark",
                    "planType": "prolite",
                    "primary": ["usedPercent": 18, "windowDurationMins": 300, "resetsAt": 1_008_000],
                    "secondary": ["usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1_600_000],
                    "rateLimitReachedType": NSNull(),
                ],
            ],
            "rateLimitResetCredits": NSNull(),
        ]

        let snap = parseCodexRateLimits(json)

        XCTAssertEqual(snap?.buckets.keys.sorted(), ["codex", "codex_bengalfox"])
        XCTAssertEqual(snap?.windows.map(\.label), ["7d"])
        XCTAssertEqual(snap?.windows.map(\.window.utilization), [7])
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

    func testMergeSparseUpdateChangesOnlyMatchingBucket() {
        let base = CodexRateLimitsSnapshot(buckets: [
            "codex": CodexRateLimitBucket(
                id: "codex", name: nil,
                primary: LabeledWindow(label: "7d",
                                       window: UsageWindow(utilization: 7, resetUnix: 1)),
                secondary: nil),
            "codex_bengalfox": CodexRateLimitBucket(
                id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                primary: LabeledWindow(label: "5h",
                                       window: UsageWindow(utilization: 18, resetUnix: 2)),
                secondary: LabeledWindow(label: "7d",
                                         window: UsageWindow(utilization: 4, resetUnix: 3))),
        ])
        let update = CodexRateLimitsSnapshot(buckets: [
            "codex_bengalfox": CodexRateLimitBucket(
                id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                primary: LabeledWindow(label: "5h",
                                       window: UsageWindow(utilization: 85, resetUnix: 4)),
                secondary: nil),
        ])

        let merged = mergeCodex(into: base, update: update)

        XCTAssertEqual(merged.buckets["codex"]?.primary?.window.utilization, 7)
        XCTAssertEqual(merged.buckets["codex_bengalfox"]?.primary?.window.utilization, 85)
        XCTAssertEqual(merged.buckets["codex_bengalfox"]?.secondary?.window.utilization, 4)
    }

    func testMergeIntoNilReturnsUpdate() {
        let update = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 7, resetUnix: nil)),
            secondary: nil)
        XCTAssertEqual(mergeCodex(into: nil, update: update), update)
    }
}
