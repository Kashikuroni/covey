import XCTest
@testable import covey

@MainActor
final class UsageSnapshotStoreTests: XCTestCase {
    func testFailedSettingsRemainRetryableAndSameRevisionCanConfirmRecovery() {
        let store = UsageStore()
        store.beginSubscription()
        XCTAssertFalse(store.isAvailable)
        store.apply(UsageSnapshot())
        store.failed(IPCClientError.daemonError(code: "usageSettingsFailed", message: "disk full"))
        XCTAssertTrue(store.isAvailable)
        XCTAssertNotNil(store.connectionError)
        store.apply(UsageSnapshot())
        XCTAssertNil(store.connectionError)
        store.disconnected()
        XCTAssertFalse(store.isAvailable)
    }

    func testOlderResponsesCannotOverwriteNewerEvents() {
        let store = UsageStore()
        var newer = UsageSnapshot()
        newer.revision = 3
        newer.plan = "Pro"
        store.apply(newer)
        var older = UsageSnapshot()
        older.revision = 2
        store.apply(older)
        XCTAssertEqual(store.snapshot.plan, "Pro")
        store.beginSubscription()
        store.apply(UsageSnapshot())
        XCTAssertNil(store.snapshot.plan, "A restarted daemon can start again at revision zero")
    }

    func testAlertsAreDeliveredOnceAcrossDuplicateSnapshots() {
        var markers: [String: Int64] = [:]
        var delivered: [LimitAlert] = []
        let store = UsageStore(readMarkers: { markers }, writeMarkers: { markers = $0 })
        store.alertSink = { delivered += $0 }
        var snapshot = UsageSnapshot()
        snapshot.revision = 1
        snapshot.usage = Usage(fiveHour: UsageWindow(utilization: 85, resetUnix: 10),
                               sevenDay: nil, sevenDaySonnet: nil)
        snapshot.codexState = .active(CodexAccount(type: "chatgpt", planType: "pro"))
        snapshot.codexUsage = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 90, resetUnix: 20)),
            secondary: nil)
        store.apply(snapshot)
        store.apply(snapshot)
        snapshot.revision = 2
        store.apply(snapshot)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(markers, ["claude:5h": 10, "codex:5h": 20])
        snapshot.revision = 3
        snapshot.usage?.fiveHour?.resetUnix = 30
        store.apply(snapshot)
        XCTAssertEqual(delivered.count, 3)
    }

    func testGLMWindowsAlertLikeOtherProviders() {
        var markers: [String: Int64] = [:]
        var delivered: [LimitAlert] = []
        let store = UsageStore(readMarkers: { markers }, writeMarkers: { markers = $0 })
        store.alertSink = { delivered += $0 }
        var snapshot = UsageSnapshot()
        snapshot.revision = 1
        snapshot.glmQuota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 25200, remaining: 2800,
                                      usedPercent: 90, remainingPercent: 10,
                                      resetAt: 1_790_943_951_592),
            weekly: GLMLimitWindow(total: 140000, used: 21000, remaining: 119000,
                                   usedPercent: 15, remainingPercent: 85,
                                   resetAt: 1_791_529_507_983)))
        store.apply(snapshot)
        XCTAssertEqual(delivered.count, 1, "only the 5h window crosses the threshold")
        XCTAssertEqual(markers, ["glm:5h": 1_790_943_951])
        // Disabled polling must not alert.
        delivered.removeAll()
        markers.removeAll()
        snapshot.revision = 2
        snapshot.glmUsageEnabled = false
        snapshot.glmQuota?.limits.fiveHours?.usedPercent = 95
        store.apply(snapshot)
        XCTAssertTrue(delivered.isEmpty)
        // A fetch error must not alert from the stale cached quota either —
        // the same guard Claude has.
        var errored = UsageSnapshot()
        errored.revision = 1
        errored.glmQuota = snapshot.glmQuota
        errored.glmUsageError = "net"
        store.apply(errored)
        XCTAssertTrue(delivered.isEmpty)
    }
}
