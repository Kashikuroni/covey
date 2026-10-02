import XCTest
@testable import CoveyKit

final class RetiredUsageCompatibilityTests: XCTestCase {
    func testOldSnapshotIgnoresRetiredGLMCacheKey() throws {
        var original = UsageSnapshot()
        original.usage = Usage(fiveHour: UsageWindow(utilization: 42))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["glmUsage"] = ["fiveHour": ["utilization": 100]]
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.glmQuota, "retired glmUsage cache must not leak into glmQuota")
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
