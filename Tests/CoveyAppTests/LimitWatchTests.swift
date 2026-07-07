import XCTest
@testable import covey

final class LimitWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func usage(five: UsageWindow? = nil, seven: UsageWindow? = nil,
                       sonnet: UsageWindow? = nil) -> Usage {
        Usage(fiveHour: five, sevenDay: seven, sevenDaySonnet: sonnet)
    }

    func testCrossingEmitsAlertAndMark() {
        let u = usage(five: UsageWindow(utilization: 82, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h"])
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testSameWindowDeduped() {
        let u = usage(five: UsageWindow(utilization: 91, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testNewResetCycleAlertsAgain() {
        let u = usage(five: UsageWindow(utilization: 85, resetUnix: 1_020_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(marks, ["5h": 1_020_000])
    }

    func testDropBelowThresholdClearsMark() {
        let u = usage(five: UsageWindow(utilization: 30, resetUnix: 1_020_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, [:])
    }

    func testNilResetsAtUsesZeroMark() {
        let u = usage(five: UsageWindow(utilization: 82, resetUnix: nil))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].body, "18% left")   // no reset tail
        XCTAssertEqual(marks, ["5h": 0])
        // Second pass: silent.
        let again = limitAlerts(usage: u, notified: marks, now: now)
        XCTAssertTrue(again.alerts.isEmpty)
    }

    func testSonnetWindowIgnored() {
        let u = usage(sonnet: UsageWindow(utilization: 99, resetUnix: 1_008_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertTrue(marks.isEmpty)
    }

    func testBothWindowsAlertTogether() {
        let u = usage(five: UsageWindow(utilization: 80, resetUnix: 1_008_000),
                      seven: UsageWindow(utilization: 95, resetUnix: 1_600_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts.map(\.windowKey), ["5h", "7d"])
        XCTAssertEqual(marks, ["5h": 1_008_000, "7d": 1_600_000])
    }

    func testMissingWindowKeepsMark() {
        // Network hiccup can drop a window from the payload; the current
        // cycle's dedup must survive it.
        let u = usage(seven: UsageWindow(utilization: 10, resetUnix: 1_600_000))
        let (alerts, marks) = limitAlerts(usage: u, notified: ["5h": 1_008_000], now: now)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(marks, ["5h": 1_008_000])
    }

    func testAlertTextContent() {
        // reset = now + 2h13m exactly; remainingLabel ceils to "2h13m".
        let reset = Int64(1_000_000 + 2 * 3600 + 13 * 60)
        let u = usage(five: UsageWindow(utilization: 82.4, resetUnix: reset))
        let (alerts, _) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 82%")
        XCTAssertEqual(alerts[0].body, "18% left · resets in 2h13m")
    }

    func testOverHundredClampsRemainderToZero() {
        let u = usage(five: UsageWindow(utilization: 104, resetUnix: nil))
        let (alerts, _) = limitAlerts(usage: u, notified: [:], now: now)
        XCTAssertEqual(alerts[0].title, "Claude 5h limit at 104%")
        XCTAssertEqual(alerts[0].body, "0% left")
    }
}
