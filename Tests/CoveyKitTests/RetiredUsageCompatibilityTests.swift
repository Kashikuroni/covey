import XCTest
@testable import CoveyKit

final class RetiredUsageCompatibilityTests: XCTestCase {
    func testOldSnapshotIgnoresRetiredProviderFields() throws {
        var original = UsageSnapshot()
        original.usage = Usage(fiveHour: UsageWindow(utilization: 42))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["glmUsageEnabled"] = true
        json["glmUsage"] = ["fiveHour": ["utilization": 100]]
        json["glmUsageError"] = "offline"
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(UsageProvider.allCases, [.claude, .codex])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("glm"))
    }

    func testOldUIStateIgnoresRetiredProviderCache() throws {
        let original = PersistedState(theme: "dark")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["glmUsageEnabled"] = true
        json["glmUsage"] = ["fiveHour": ["utilization": 100]]
        let state = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(state, original)
        XCTAssertEqual(state.theme, "dark")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("glm"))
    }
}
