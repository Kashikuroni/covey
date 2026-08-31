import XCTest
@testable import covey
import CoveyKit

@MainActor
final class UsageStoreTests: XCTestCase {
    private func makeStore(
        fetchAccount: @escaping () async -> Account = { Account() },
        fetchGlm: @escaping () async -> Account = { Account() }
    ) -> (store: UsageStore, persisted: PersistedState) {
        let persisted = PersistedState()
        let store = UsageStore(fetchAccount: fetchAccount,
                               fetchGlmAccount: fetchGlm,
                               onPersist: {})
        return (store, persisted)
    }

    func testTogglesDefaultTrue() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.claudeUsageEnabled)
        XCTAssertTrue(store.codexUsageEnabled)
        XCTAssertTrue(store.glmUsageEnabled)
    }

    func testStateRestoresFromPersistedCache() {
        var persisted = PersistedState()
        persisted.claudeUsage = PersistedUsage(
            fiveHour: PersistedUsageWindow(utilization: 42))
        persisted.codexUsage = PersistedCodexUsage(
            primaryLabel: "5h", primary: PersistedUsageWindow(utilization: 10))
        persisted.codexPlan = "Pro"
        let (store, _) = makeStore()
        store.restoreFromPersisted(persisted)
        XCTAssertEqual(store.usage?.fiveHour?.utilization, 42)
        XCTAssertEqual(store.codexUsage?.primary?.label, "5h")
        XCTAssertEqual(store.codexPlan, "Pro")
    }

    func testTickClaudeAppliesUsageAndPlan() async {
        var calls = 0
        let (store, _) = makeStore(fetchAccount: {
            calls += 1
            return Account(usage: Usage(fiveHour: UsageWindow(utilization: 50, resetUnix: nil),
                                        sevenDay: nil, sevenDaySonnet: nil),
                           plan: "Max")
        })
        await store.tickClaude()
        XCTAssertEqual(store.usage?.fiveHour?.utilization, 50)
        XCTAssertEqual(store.plan, "Max")
        XCTAssertNil(store.usageError)
        XCTAssertEqual(calls, 1)
    }

    func testTickClaudeErrorKeepsLastGoodUsage() async {
        let good = Usage(fiveHour: UsageWindow(utilization: 10, resetUnix: nil),
                         sevenDay: nil, sevenDaySonnet: nil)
        var calls = 0
        let (store, _) = makeStore(fetchAccount: {
            calls += 1
            return calls == 1
                ? Account(usage: good, plan: "Max")
                : Account(usageError: "401")
        })
        await store.tickClaude()
        XCTAssertEqual(store.usage?.fiveHour?.utilization, 10)
        await store.tickClaude()
        XCTAssertEqual(store.usage?.fiveHour?.utilization, 10)   // last good survives
        XCTAssertEqual(store.usageError, "401")
        XCTAssertEqual(store.plan, "Max")                         // plan cache survives too
    }

    func testTickClaudeDisabledSkipsFetch() async {
        var calls = 0
        let (store, _) = makeStore(fetchAccount: { calls += 1; return Account() })
        store.claudeUsageEnabled = false
        await store.tickClaude()
        XCTAssertEqual(calls, 0)
    }

    func testTickGlmDisabledSkipsFetch() async {
        var calls = 0
        let (store, _) = makeStore(fetchGlm: { calls += 1; return Account() })
        store.glmUsageEnabled = false
        await store.tickGlm()
        XCTAssertEqual(calls, 0)
    }
}
