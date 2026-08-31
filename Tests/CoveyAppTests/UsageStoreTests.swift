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
}
