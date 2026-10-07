import XCTest
@testable import covey
import CoveyKit

final class UsagePersistenceTests: XCTestCase {
    func testPersistedUsageWindowRoundTrip() {
        let w = UsageWindow(utilization: 42, resetUnix: 1_700_000_000)
        XCTAssertEqual(PersistedUsageWindow(w).live, w)
    }

    func testPersistedUsageRoundTripWithPartialWindows() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 55, resetUnix: 1),
                          sevenDay: nil, sevenDaySonnet: nil)
        XCTAssertEqual(PersistedUsage(usage).live, usage)
    }

    func testPersistedUsageRoundTripAllNil() {
        let usage = Usage(fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil)
        XCTAssertEqual(PersistedUsage(usage).live, usage)
    }

    func testPersistedCodexUsageRoundTrip() {
        let snap = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 22, resetUnix: 2)))
        XCTAssertEqual(PersistedCodexUsage(snap).live, snap)
    }

    func testPersistedCodexUsagePreservesDurations() {
        var snap = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                   window: UsageWindow(utilization: 8, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", durationMinutes: 10_080,
                                     window: UsageWindow(utilization: 22, resetUnix: 2)))
        snap.buckets["team"] = CodexRateLimitBucket(
            id: "team", name: "Team",
            primary: LabeledWindow(label: "5h",
                                   durationMinutes: 300,
                                   window: UsageWindow(utilization: 3, resetUnix: 5)),
            secondary: nil)
        let restored = PersistedCodexUsage(snap).live
        XCTAssertEqual(restored.primary?.durationMinutes, 300, "легаси-поля несут duration")
        XCTAssertEqual(restored.secondary?.durationMinutes, 10_080)
        XCTAssertEqual(restored.buckets["team"]?.primary?.durationMinutes, 300)
    }

    func testPersistedCodexUsageRoundTripsEveryBucket() {
        let snap = CodexRateLimitsSnapshot(buckets: [
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

        XCTAssertEqual(PersistedCodexUsage(snap).live, snap)
    }

    func testPersistedCodexUsagePrimaryOnlyRoundTrip() {
        let snap = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "primary", window: UsageWindow(utilization: 9, resetUnix: nil)),
            secondary: nil)
        XCTAssertEqual(PersistedCodexUsage(snap).live, snap)
    }

    func testPersistedCodexUsageEmptyRoundTrip() {
        let snap = CodexRateLimitsSnapshot(primary: nil, secondary: nil)
        XCTAssertEqual(PersistedCodexUsage(snap).live, snap)
    }
}
