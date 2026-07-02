import XCTest
@testable import covey
import CoveyKit

final class AppModelUsageTests: XCTestCase {
    @MainActor
    private func makeUsageModel(_ daemon: TestDaemon,
                                fetch: @escaping () async -> Account,
                                interval: TimeInterval = 0.05) throws -> AppModel {
        let client = IPCClient(path: daemon.path); try client.connect()
        let statePath = "\(NSTemporaryDirectory())covey-usage-\(UInt32.random(in: 0..<UInt32.max)).json"
        return AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: fetch,
            usageInterval: interval)
    }

    @MainActor
    func testPollerAppliesUsageAndPlan() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let acc = Account(usage: Usage(fiveHour: UsageWindow(utilization: 55, resetUnix: nil, resetHHMM: nil),
                                       sevenDay: nil, sevenDaySonnet: nil),
                          plan: "Max 5×", usageError: nil)
        let model = try makeUsageModel(daemon, fetch: { acc })
        await model.start()
        let ok = await eventually { model.usage?.fiveHour?.utilization == 55 && model.plan == "Max 5×" }
        XCTAssertTrue(ok)
        XCTAssertNil(model.usageError)
    }

    @MainActor
    func testPollerAppliesPartialError() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account(usageError: "429") })
        await model.start()
        let ok = await eventually { model.usageError == "429" }
        XCTAssertTrue(ok)
        XCTAssertNil(model.usage)
    }

    @MainActor
    func testPollerRefreshesOnNextTick() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(usageError: "net")
        let model = try makeUsageModel(daemon, fetch: { box.value })
        await model.start()
        _ = await eventually { model.usageError == "net" }
        box.value = Account(plan: "Pro")
        let refreshed = await eventually { model.plan == "Pro" && model.usageError == nil }
        XCTAssertTrue(refreshed)
    }
}

/// Mutable holder so the fetch closure can return changing values across ticks.
final class AccountBox: @unchecked Sendable { var value = Account() }
