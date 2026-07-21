import XCTest
@testable import covey

final class UsageChipTests: XCTestCase {
    func testUsageChipItemsPutPlanBeforeWindows() {
        let five = UsageWindow(utilization: 42, resetUnix: 1_750_003_600)
        let seven = UsageWindow(utilization: 18, resetUnix: 1_750_086_400)
        let sonnet = UsageWindow(utilization: 7, resetUnix: nil)
        let usage = Usage(fiveHour: five, sevenDay: seven, sevenDaySonnet: sonnet)

        XCTAssertEqual(usageChipItems(usage: usage, plan: "Claude"), [
            .plan("Claude"),
            .window("5h", five),
            .window("7d", seven),
            .window("S 7d", sonnet),
        ])
    }

    func testUsageChipItemsStartWithFirstWindowWhenPlanMissing() {
        let five = UsageWindow(utilization: 42, resetUnix: nil)
        let usage = Usage(fiveHour: five, sevenDay: nil, sevenDaySonnet: nil)

        XCTAssertEqual(usageChipItems(usage: usage, plan: nil), [
            .window("5h", five),
        ])
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func label(afterSeconds secs: Int64) -> String {
        remainingLabel(resetUnix: 1_750_000_000 + secs, now: now)
    }

    func testRemainingLabelExpired() {
        XCTAssertEqual(label(afterSeconds: 0), "0m")
        XCTAssertEqual(label(afterSeconds: -3600), "0m")
    }

    func testRemainingLabelMinutes() {
        XCTAssertEqual(label(afterSeconds: 60), "1m")
        XCTAssertEqual(label(afterSeconds: 37 * 60), "37m")
        XCTAssertEqual(label(afterSeconds: 59 * 60), "59m")
    }

    func testRemainingLabelHours() {
        XCTAssertEqual(label(afterSeconds: 3600), "1h")
        XCTAssertEqual(label(afterSeconds: (2 * 60 + 13) * 60), "2h13m")
        XCTAssertEqual(label(afterSeconds: (23 * 60 + 59) * 60), "23h59m")
    }

    func testRemainingLabelDays() {
        XCTAssertEqual(label(afterSeconds: 24 * 3600), "1d")
        XCTAssertEqual(label(afterSeconds: (3 * 24 + 4) * 3600), "3d4h")
    }

    func testRemainingLabelCeilsPartialMinutes() {
        // 61s is "2 minutes to go" — never show less time than remains.
        XCTAssertEqual(label(afterSeconds: 61), "2m")
    }

    func testUsageLevelThresholds() {
        // amux CLI thresholds: <50 ok, 50–79 warn, ≥80 err.
        XCTAssertEqual(usageLevel(0), .ok)
        XCTAssertEqual(usageLevel(49), .ok)
        XCTAssertEqual(usageLevel(50), .warn)
        XCTAssertEqual(usageLevel(79), .warn)
        XCTAssertEqual(usageLevel(80), .err)
        XCTAssertEqual(usageLevel(100), .err)
    }
}
