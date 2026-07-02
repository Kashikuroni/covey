import XCTest
@testable import covey

final class UsageParseTests: XCTestCase {
    func testParseUsageExtractsWindows() {
        let body = Data(#"""
        {"five_hour": {"utilization": 77.0, "resets_at": "2026-06-02T10:40:01Z"},
         "seven_day": {"utilization": 40.0, "resets_at": null},
         "seven_day_sonnet": null}
        """#.utf8)
        let u = parseUsage(body)!
        XCTAssertEqual(u.fiveHour?.utilization, 77.0)
        XCTAssertEqual(u.fiveHour?.resetUnix, parseISO8601("2026-06-02T10:40:01Z"))
        XCTAssertEqual(u.sevenDay?.utilization, 40.0)
        XCTAssertNil(u.sevenDay?.resetUnix)
        XCTAssertNil(u.sevenDaySonnet)
    }

    func testParseUsageAllNullReturnsNil() {
        let body = Data(#"{"five_hour": null, "seven_day": null, "seven_day_sonnet": null}"#.utf8)
        XCTAssertNil(parseUsage(body))
    }

    func testParseUsageGarbageReturnsNil() {
        XCTAssertNil(parseUsage(Data("not json".utf8)))
    }

    func testParsePlan() {
        XCTAssertEqual(parsePlan(Data(#"{"organization": {"rate_limit_tier": "default_claude_max_5x"}}"#.utf8)), "Max 5×")
        XCTAssertNil(parsePlan(Data("{}".utf8)))
    }

    func testPlanLabel() {
        XCTAssertEqual(planLabel("default_claude_max_5x"), "Max 5×")
        XCTAssertEqual(planLabel("claude_pro"), "Pro")
        XCTAssertEqual(planLabel("some_team_plan"), "Team")
        XCTAssertEqual(planLabel("enterprise_thing"), "Enterprise")
        XCTAssertEqual(planLabel("weird"), "Claude")
    }

    func testParseISO8601() {
        // Compare against a Foundation-computed reference (no magic epoch number).
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 2; c.hour = 10; c.minute = 40; c.second = 1
        c.timeZone = TimeZone(identifier: "UTC")
        let expected = Int64(Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970)
        XCTAssertEqual(parseISO8601("2026-06-02T10:40:01Z"), expected)
        XCTAssertNil(parseISO8601("nonsense"))
    }
}
