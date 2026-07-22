import XCTest
@testable import covey

final class LimitWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func claudeWindows(five: UsageWindow? = nil, seven: UsageWindow? = nil)
        -> [(key: String, window: UsageWindow?)] {
        [("5h", five), ("7d", seven)]
    }

    func testCrossingEmitsAlertAndMark() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 82, resetUnix: 1_008_000)),
            notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h"])
        XCTAssertEqual(marks, ["claude:5h": 1_008_000])
    }

    func testSameWindowDeduped() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 91, resetUnix: 1_008_000)),
            notified: ["claude:5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["claude:5h": 1_008_000])
    }

    func testNewResetCycleAlertsAgain() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 85, resetUnix: 1_020_000)),
            notified: ["claude:5h": 1_008_000], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(marks, ["claude:5h": 1_020_000])
    }

    func testDropBelowThresholdClearsMark() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 30, resetUnix: 1_020_000)),
            notified: ["claude:5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, [:])
    }

    func testNilResetsAtUsesZeroMark() {
        let windows = claudeWindows(five: UsageWindow(utilization: 82, resetUnix: nil))
        let (alerts, marks) = limitAlerts(agent: "Claude", windows: windows,
                                          notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].body, "18% left")
        XCTAssertEqual(marks, ["claude:5h": 0])
        let again = limitAlerts(agent: "Claude", windows: windows, notified: marks, now: now)
        XCTAssertTrue(again.alerts.isEmpty)
    }

    func testBothWindowsAlertTogether() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 80, resetUnix: 1_008_000),
                                   seven: UsageWindow(utilization: 95, resetUnix: 1_600_000)),
            notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h", "7d"])
        XCTAssertEqual(marks, ["claude:5h": 1_008_000, "claude:7d": 1_600_000])
    }

    func testMissingWindowKeepsMark() {
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(seven: UsageWindow(utilization: 10, resetUnix: 1_600_000)),
            notified: ["claude:5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["claude:5h": 1_008_000])
    }

    func testAlertTextContent() {
        let reset = Int64(1_000_000 + 2 * 3600 + 13 * 60)
        let (alerts, _) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 82.4, resetUnix: reset)),
            notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 82%")
        XCTAssertEqual(alerts[0].body, "18% left · resets in 2h13m")
    }

    func testOverHundredClampsRemainderToZero() {
        let (alerts, _) = limitAlerts(
            agent: "Claude",
            windows: claudeWindows(five: UsageWindow(utilization: 104, resetUnix: nil)),
            notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 104%")
        XCTAssertEqual(alerts[0].body, "0% left")
    }

    func testCodexTitleAndPrefixedMarker() {
        let (alerts, marks) = limitAlerts(
            agent: "Codex",
            windows: [("5h", UsageWindow(utilization: 90, resetUnix: 1_008_000))],
            notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Codex 5h limit at 90%")
        XCTAssertEqual(marks, ["codex:5h": 1_008_000])
    }

    func testAgentMarkersDoNotCollide() {
        // A Codex pass must preserve an existing Claude marker in the shared map.
        let (alerts, marks) = limitAlerts(
            agent: "Codex",
            windows: [("5h", UsageWindow(utilization: 85, resetUnix: 2_000_000))],
            notified: ["claude:5h": 1_008_000], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(marks, ["claude:5h": 1_008_000, "codex:5h": 2_000_000])
    }
}
