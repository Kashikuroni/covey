import XCTest
import CoveyKit

final class UsageNumericValidationTests: XCTestCase {
    func testExtremeNetworkNumbersDoNotBecomeUsage() throws {
        for number in ["1e100", "-1"] {
            XCTAssertNil(parseUsage(Data("{\"five_hour\":{\"utilization\":\(number)}}".utf8)))
            let codex = try JSONSerialization.jsonObject(with: Data("{\"primary\":{\"usedPercent\":\(number)}}".utf8)) as! [String: Any]
            XCTAssertNil(parseCodexRateLimits(codex))
        }
    }

    func testOverLimitPercentagesArePreserved() {
        XCTAssertEqual(parseUsage(Data(#"{"five_hour":{"utilization":104}}"#.utf8))?.fiveHour?.utilization, 104)
        XCTAssertEqual(parseCodexRateLimits(["primary": ["usedPercent": 104]])?.primary?.window.utilization, 104)
    }

    func testExtremeNetworkDurationsAndResetTimesAreIgnored() throws {
        let codex = try JSONSerialization.jsonObject(with: Data(#"{"primary":{"usedPercent":42,"windowDurationMins":1e100,"resetsAt":1e100}}"#.utf8)) as! [String: Any]
        let snapshot = parseCodexRateLimits(codex)
        XCTAssertEqual(snapshot?.primary?.window.utilization, 42)
        XCTAssertEqual(snapshot?.primary?.label, "primary")
        XCTAssertNil(snapshot?.primary?.window.resetUnix)
    }

    func testNonfiniteAndIntegerBoundaryCodexValuesAreSafe() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(parseCodexRateLimits(["primary": ["usedPercent": invalid]]))
        }
        for invalid in [Double.nan, .infinity, -.infinity, Double(Int64.max), -1e100] {
            let parsed = parseCodexRateLimits(["primary": ["usedPercent": 50, "windowDurationMins": invalid, "resetsAt": invalid]])
            XCTAssertEqual(parsed?.primary?.window.utilization, 50)
            XCTAssertEqual(parsed?.primary?.label, "primary")
            XCTAssertNil(parsed?.primary?.window.resetUnix)
        }
    }
}
