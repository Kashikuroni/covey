import XCTest
import CoveyKit
@testable import covey

final class PMAnalyticsFormatTests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(PMFormat.tokens(1_500_000), "1.5M")
        XCTAssertEqual(PMFormat.tokens(42_000), "42k")
        XCTAssertEqual(PMFormat.tokens(999), "999")
    }

    func testUsd() {
        XCTAssertEqual(PMFormat.usd(0), "$0.00")
        XCTAssertEqual(PMFormat.usd(1.234), "$1.23")
        XCTAssertEqual(PMFormat.usd(1234.5), "$1234.50")
    }

    func testMinutes() {
        XCTAssertEqual(PMFormat.minutes(45), "45m")
        XCTAssertEqual(PMFormat.minutes(90), "1h 30m")
        XCTAssertEqual(PMFormat.minutes(1440), "24h")
    }
}
