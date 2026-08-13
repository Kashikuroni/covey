import XCTest
@testable import covey

final class GlmUsageParseTests: XCTestCase {
    func testParseGlmQuotaExtractsTokensLimitAsFiveHour() {
        let body = Data(#"""
        {"data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 42, "nextResetTime": 1755999999000},
            {"type": "TIME_LIMIT", "percentage": 5, "nextResetTime": 1758000000000}
        ]}}
        """#.utf8)
        let u = parseGlmQuota(body)!
        XCTAssertEqual(u.fiveHour?.utilization, 42)
        XCTAssertEqual(u.fiveHour?.resetUnix, 1755999999)
        XCTAssertNil(u.sevenDay)
        XCTAssertNil(u.sevenDaySonnet)
    }

    func testParseGlmQuotaMissingTokensLimitReturnsNil() {
        let body = Data(#"""
        {"data": {"limits": [
            {"type": "TIME_LIMIT", "percentage": 5, "nextResetTime": 1758000000000}
        ]}}
        """#.utf8)
        XCTAssertNil(parseGlmQuota(body))
    }

    func testParseGlmQuotaGarbageReturnsNil() {
        XCTAssertNil(parseGlmQuota(Data("not json".utf8)))
    }

    func testParseGlmQuotaMissingResetTimeStillParses() {
        let body = Data(#"""
        {"data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 10}
        ]}}
        """#.utf8)
        let u = parseGlmQuota(body)!
        XCTAssertEqual(u.fiveHour?.utilization, 10)
        XCTAssertNil(u.fiveHour?.resetUnix)
    }
}
