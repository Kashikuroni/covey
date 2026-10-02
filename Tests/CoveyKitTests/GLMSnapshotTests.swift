import XCTest
@testable import CoveyKit

/// GLM's slot on the daemon snapshot: fields decode with defaults when a
/// pre-GLM `usage.json` lacks them, and the retired `glmUsage` cache key
/// (old app-side shape) must not leak into the new `glmQuota`.
final class GLMSnapshotTests: XCTestCase {
    private let quota = GLMQuota(plan: "max", limits: GLMLimits(
        fiveHours: GLMLimitWindow(total: 28000, used: 5695, remaining: 22304,
                                  usedPercent: 20, remainingPercent: 80,
                                  resetAt: 1_790_943_951_592)))

    func testProviderEnumIncludesGLM() {
        XCTAssertEqual(UsageProvider.allCases, [.claude, .codex, .glm])
        XCTAssertEqual(UsageProvider.glm.rawValue, "glm")
    }

    func testPreGLMSnapshotDecodesWithDefaults() throws {
        // Shape written before GLM existed — no glm keys at all.
        let legacy = """
        {"revision": 7, "usage": {"fiveHour": {"utilization": 42}},
         "plan": "Max", "claudeUsageEnabled": false, "codexUsageEnabled": true,
         "codexState": {"stopped": {}}}
        """
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.usage?.fiveHour, UsageWindow(utilization: 42))
        XCTAssertFalse(decoded.claudeUsageEnabled)
        XCTAssertTrue(decoded.glmUsageEnabled)
        XCTAssertNil(decoded.glmQuota)
        XCTAssertNil(decoded.glmUsageError)
    }

    func testRetiredGLMUsageKeyIgnoredOnDecode() throws {
        // `glmUsage` is the retired app-side cache key; `glmUsageError` is a
        // live field again, so only the retired key must stay ignored.
        let legacy = """
        {"glmUsage": {"fiveHour": {"utilization": 100}}}
        """
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.glmQuota)
    }

    func testSnapshotRoundTripsGLMFields() throws {
        var snapshot = UsageSnapshot()
        snapshot.glmQuota = quota
        snapshot.glmUsageError = nil
        snapshot.glmUsageEnabled = false
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["glmUsageEnabled"] as? Bool, false)
        XCTAssertEqual((json["glmQuota"] as? [String: Any])?["plan"] as? String, "max")
    }
}
