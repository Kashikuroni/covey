import XCTest
import SwiftUI
@testable import covey

final class UsageHeaderTests: XCTestCase {
    func testDisplayPercentBoundsLegacyCachedValues() {
        XCTAssertNil(displayUsagePercent(1e100))
        XCTAssertNil(displayUsagePercent(-1e100))
        XCTAssertEqual(displayUsagePercent(104), 104)
        XCTAssertNil(displayUsagePercent(.nan))
        XCTAssertNil(displayUsagePercent(.infinity))
    }

    func testExtremeResetTimesDoNotOverflowCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(remainingLabel(resetUnix: .min, now: now), "0m")
        XCTAssertFalse(remainingLabel(resetUnix: .max, now: now).isEmpty)
    }

    func testLevelColorMapsToTokens() {
        let tk = Tokens.dark
        XCTAssertEqual(levelColor(.ok, tk: tk), tk.ok)
        XCTAssertEqual(levelColor(.warn, tk: tk), tk.warn)
        XCTAssertEqual(levelColor(.err, tk: tk), tk.err)
    }

    func testCodexHeaderWindowUsesHighestUtilizationWithinLegacyBucket() {
        let snap = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 22, resetUnix: 2)))
        XCTAssertEqual(codexHeaderWindow(snap)?.utilization, 22)
    }

    func testCodexHeaderWindowUsesHighestUtilizationAcrossBuckets() {
        let snap = CodexRateLimitsSnapshot(buckets: [
            "codex": CodexRateLimitBucket(
                id: "codex", name: nil,
                primary: LabeledWindow(label: "7d",
                                       window: UsageWindow(utilization: 7, resetUnix: 1)),
                secondary: nil),
            "codex_bengalfox": CodexRateLimitBucket(
                id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                primary: LabeledWindow(label: "5h",
                                       window: UsageWindow(utilization: 38, resetUnix: 2)),
                secondary: LabeledWindow(label: "7d",
                                         window: UsageWindow(utilization: 4, resetUnix: 3))),
        ])

        XCTAssertEqual(codexHeaderWindow(snap)?.utilization, 38)
    }

    func testCodexHeaderWindowHandlesArbitraryLabelsAndMissingWindows() {
        let mislabeled = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "primary", window: UsageWindow(utilization: 9, resetUnix: nil)),
            secondary: LabeledWindow(label: "secondary", window: UsageWindow(utilization: 30, resetUnix: nil)))
        XCTAssertEqual(codexHeaderWindow(mislabeled)?.utilization, 30,
                       "labels do not affect utilization comparison")

        let primaryOnly = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "primary", window: UsageWindow(utilization: 9, resetUnix: nil)),
            secondary: nil)
        XCTAssertEqual(codexHeaderWindow(primaryOnly)?.utilization, 9,
                       "a single available window is selected")
    }

    func testCodexHeaderWindowNilWhenEmpty() {
        XCTAssertNil(codexHeaderWindow(nil))
        XCTAssertNil(codexHeaderWindow(CodexRateLimitsSnapshot(primary: nil, secondary: nil)))
    }

    func testHeaderSegmentsKeepAllProvidersWhenOnlyClaudeAndCodexHaveData() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 65, resetUnix: 1),
                          sevenDay: nil, sevenDaySonnet: nil)
        let codex = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 18, resetUnix: 2)))
        let segs = headerSegments(usage: usage, usageError: nil, codexUsage: codex)
        XCTAssertEqual(segs, [
            HeaderSegment(label: "Claude", value: "65%", level: .warn),
            HeaderSegment(label: "Codex", value: "18%", level: .ok),
        ])
    }

    func testHeaderSegmentsKeepProviderNamesAndPlaceholdersOnError() {
        let segs = headerSegments(usage: nil, usageError: "network", codexUsage: nil)
        XCTAssertEqual(segs, [
            HeaderSegment(label: "Claude", value: "—", level: nil),
            HeaderSegment(label: "Codex", value: "—", level: nil),
        ])
    }

    func testHeaderSegmentsNeverOmitAbsentProviders() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 5, resetUnix: nil),
                          sevenDay: nil, sevenDaySonnet: nil)
        let segs = headerSegments(usage: usage, usageError: nil, codexUsage: nil)
        XCTAssertEqual(segs, [
            HeaderSegment(label: "Claude", value: "5%", level: .ok),
            HeaderSegment(label: "Codex", value: "—", level: nil),
        ])
    }

    func testHeaderDateTimeNoYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = DateComponents(year: 2026, month: 7, day: 24, hour: 14, minute: 32)
        let date = cal.date(from: comps)!
        let en = headerDateTime(date, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(en.contains("2026"))
        XCTAssertTrue(en.contains("14:32"))
        XCTAssertTrue(en.contains("24"))
        let ru = headerDateTime(date, locale: Locale(identifier: "ru_RU"))
        XCTAssertFalse(ru.contains("2026"))
        XCTAssertTrue(ru.contains("14:32"))
        XCTAssertTrue(ru.contains("24"))
        XCTAssertTrue(ru.contains("июля"),
                      "Russian locale must render the genitive month form")
    }
}
