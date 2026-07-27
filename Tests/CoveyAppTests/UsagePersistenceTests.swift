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
