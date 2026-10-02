import XCTest
@testable import CoveyKit

final class GlmUsageParseTests: XCTestCase {
    /// Live response captured from GET /api/monitor/usage/quota/limit.
    private let fixture = """
    {"code":200,"msg":"Operation successful","data":{"limits":[
    {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":5695,
     "remaining":22304,"percentage":20,"nextResetTime":1790943951592},
    {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":140000,"currentValue":5695,
     "remaining":134304,"percentage":4,"nextResetTime":1791529507983}],
    "level":"max"},"success":true}
    """

    private func fixtureData(replacing limits: String, level: String = "max") -> Data {
        let json = """
        {"code":200,"data":{"limits":[\(limits)],"level":"\(level)"}}
        """
        return Data(json.utf8)
    }

    private var fiveHours: GLMLimitWindow {
        GLMLimitWindow(total: 28000, used: 5695, remaining: 22304,
                       usedPercent: 20, remainingPercent: 80, resetAt: 1_790_943_951_592)
    }

    private var weekly: GLMLimitWindow {
        GLMLimitWindow(total: 140000, used: 5695, remaining: 134304,
                       usedPercent: 4, remainingPercent: 96, resetAt: 1_791_529_507_983)
    }

    func testParseNormalizesFullResponse() {
        let quota = parseGLMQuota(Data(fixture.utf8))
        XCTAssertEqual(quota, GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: fiveHours, weekly: weekly)))
    }

    func testParseSoleWindow() {
        let data = fixtureData(replacing: """
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":1000,"currentValue":250,
         "remaining":750,"percentage":25,"nextResetTime":1790943951592}
        """)
        let quota = parseGLMQuota(data)
        XCTAssertEqual(quota?.limits.fiveHours,
                       GLMLimitWindow(total: 1000, used: 250, remaining: 750,
                                      usedPercent: 25, remainingPercent: 75,
                                      resetAt: 1_790_943_951_592))
        XCTAssertNil(quota?.limits.weekly)
    }

    func testParseIgnoresUnknownEntriesAndOtherTypes() {
        let data = fixtureData(replacing: """
        {"type":"TIME_LIMIT","unit":3,"number":5,"usage":9,"currentValue":1,
         "remaining":8,"percentage":11,"nextResetTime":1},
        {"type":"CREDIT_LIMIT","unit":4,"number":2,"usage":9,"currentValue":1,
         "remaining":8,"percentage":11,"nextResetTime":1},
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":5695,
         "remaining":22304,"percentage":20,"nextResetTime":1790943951592}
        """)
        let quota = parseGLMQuota(data)
        XCTAssertEqual(quota?.limits.fiveHours, fiveHours)
        XCTAssertNil(quota?.limits.weekly)
    }

    func testParseRejectsInvalidPercentageAndKeepsOtherWindow() {
        let data = fixtureData(replacing: """
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":5695,
         "remaining":22304,"percentage":1e100,"nextResetTime":1790943951592},
        {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":140000,"currentValue":5695,
         "remaining":134304,"percentage":4,"nextResetTime":1791529507983}
        """)
        let quota = parseGLMQuota(data)
        XCTAssertNil(quota?.limits.fiveHours)
        XCTAssertEqual(quota?.limits.weekly, weekly)
    }

    func testParseReturnsNilWithoutUsableWindows() {
        XCTAssertNil(parseGLMQuota(fixtureData(replacing: """
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":5695,
         "remaining":22304,"percentage":-1,"nextResetTime":1790943951592}
        """)))
        XCTAssertNil(parseGLMQuota(fixtureData(replacing: "")))
        XCTAssertNil(parseGLMQuota(Data("not json".utf8)))
    }

    func testCodingKeysMatchNormalizedSchema() throws {
        let quota = GLMQuota(plan: "max", limits: GLMLimits(fiveHours: fiveHours, weekly: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as? [String: Any])
        XCTAssertEqual(object["plan"] as? String, "max")
        let limits = try XCTUnwrap(object["limits"] as? [String: Any])
        // Nil windows are omitted, matching every other optional in the snapshot.
        XCTAssertEqual(limits["five_hours"] is [String: Any], true)
        XCTAssertNil(limits["weekly"])
        // Both windows present → both keys present.
        let full = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GLMQuota(plan: "max", limits: GLMLimits(fiveHours: fiveHours, weekly: weekly)))) as? [String: Any])
        XCTAssertEqual(Set((full["limits"] as? [String: Any])?.keys ?? [:].keys), ["five_hours", "weekly"])
        let window = try XCTUnwrap(limits["five_hours"] as? [String: Any])
        XCTAssertEqual(window["total"] as? Double, 28000)
        XCTAssertEqual(window["used"] as? Double, 5695)
        XCTAssertEqual(window["remaining"] as? Double, 22304)
        XCTAssertEqual(window["used_percent"] as? Double, 20)
        XCTAssertEqual(window["remaining_percent"] as? Double, 80)
        XCTAssertEqual(window["reset_at"] as? Int64, 1_790_943_951_592)
        // Round-trip preserves the structure.
        XCTAssertEqual(try JSONDecoder().decode(GLMQuota.self, from: JSONEncoder().encode(quota)), quota)
    }
}
