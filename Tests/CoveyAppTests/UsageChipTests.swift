import XCTest
@testable import covey

final class UsageChipTests: XCTestCase {
    func testWindowLabelRoundsPercent() {
        let w = UsageWindow(utilization: 76.6, resetUnix: nil, resetHHMM: nil)
        XCTAssertEqual(windowLabel("5h", w), "5h 77%")
    }

    func testWindowLabelIncludesResetWhenPresent() {
        let w = UsageWindow(utilization: 40, resetUnix: nil, resetHHMM: "10:40")
        XCTAssertEqual(windowLabel("7d", w), "7d 40% · 10:40")
    }

    func testIsClaudeAgent() {
        XCTAssertTrue(isClaudeAgent("claude"))
        XCTAssertTrue(isClaudeAgent("/usr/local/bin/Claude"))
        XCTAssertFalse(isClaudeAgent("sh"))
        XCTAssertFalse(isClaudeAgent("/bin/cat"))
    }
}
