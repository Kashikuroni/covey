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
        let acc = Account(usage: Usage(fiveHour: UsageWindow(utilization: 55, resetUnix: nil),
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

    @MainActor
    func testLimitCrossingPersistsMarker() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-limit-\(UInt32.random(in: 0..<UInt32.max)).json"
        let acc = Account(usage: Usage(
            fiveHour: UsageWindow(utilization: 82, resetUnix: 1_008_000),
            sevenDay: nil, sevenDaySonnet: nil))
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { acc },
            usageInterval: 0.05)
        await model.start()
        let persisted = await eventually {
            guard let data = FileManager.default.contents(atPath: statePath),
                  let st = try? JSONDecoder().decode(PersistedState.self, from: data)
            else { return false }
            return st.usageNotified == ["claude:5h": 1_008_000]
        }
        XCTAssertTrue(persisted)
    }

    @MainActor
    func testCodexIngestMergesAndExposesWindows() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 40, resetUnix: 2))))
        // Partial update: only primary — secondary must survive.
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 55, resetUnix: 3)),
            secondary: nil))
        XCTAssertEqual(model.codexPlan, "Pro")
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 55)
        XCTAssertEqual(model.codexUsage?.secondary?.window.utilization, 40)
    }

    @MainActor
    func testCodexLimitCrossingPersistsPrefixedMarker() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-codex-\(UInt32.random(in: 0..<UInt32.max)).json"
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { Account() },
            usageInterval: 60)
        await model.start()
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "plus")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 88, resetUnix: 1_008_000)),
            secondary: nil))
        let persisted = await eventually {
            guard let data = FileManager.default.contents(atPath: statePath),
                  let st = try? JSONDecoder().decode(PersistedState.self, from: data)
            else { return false }
            return st.usageNotified?["codex:5h"] == 1_008_000
        }
        XCTAssertTrue(persisted)
    }
    @MainActor
    func testTickUsagePreservesLastKnownOnError() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(usage: Usage(fiveHour: UsageWindow(utilization: 40, resetUnix: nil),
                                         sevenDay: nil, sevenDaySonnet: nil), plan: "Pro")
        let model = try makeUsageModel(daemon, fetch: { box.value })
        await model.start()
        _ = await eventually { model.usage?.fiveHour?.utilization == 40 }
        box.value = Account(usageError: "network")
        let ok = await eventually { model.usageError == "network" }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.usage?.fiveHour?.utilization, 40,
                       "a later error must not blank out a prior success")
        XCTAssertEqual(model.plan, "Pro")
    }

    @MainActor
    func testSetCodexStateStoppedPreservesCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: nil))
        model.setCodexState(.stopped)
        XCTAssertEqual(model.codexPlan, "Pro")
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 12)
    }

    @MainActor
    func testSetCodexStateUnauthedClearsCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: nil))
        model.setCodexState(.unauthed)
        XCTAssertNil(model.codexPlan)
        XCTAssertNil(model.codexUsage)
    }

    @MainActor
    func testRestartRestoresCachedUsageBeforeFirstPoll() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-usage-cache-\(UInt32.random(in: 0..<UInt32.max)).json"
        let client1 = IPCClient(path: daemon.path); try client1.connect()
        let model1 = AppModel(
            client: client1,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { Account(usage: Usage(fiveHour: UsageWindow(utilization: 61, resetUnix: nil),
                                                 sevenDay: nil, sevenDaySonnet: nil), plan: "Max") },
            usageInterval: 0.05)
        await model1.start()
        _ = await eventually { model1.usage?.fiveHour?.utilization == 61 }
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the debounced (0.05s) save land

        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let model2 = AppModel(
            client: client2,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { Account() },   // always empty: proves a real (empty) poll can't clobber it either
            usageInterval: 0.05)
        await model2.start()
        XCTAssertEqual(model2.usage?.fiveHour?.utilization, 61,
                       "cached usage restores from disk before/around the first poll")
        XCTAssertEqual(model2.plan, "Max")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model2.usage?.fiveHour?.utilization, 61, "still 61 after several more empty polls")
    }

    @MainActor
    func testDisabledClaudeUsageStopsPolling() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(usage: Usage(fiveHour: UsageWindow(utilization: 10, resetUnix: nil),
                                         sevenDay: nil, sevenDaySonnet: nil))
        let model = try makeUsageModel(daemon, fetch: { box.value })
        await model.start()
        _ = await eventually { model.usage?.fiveHour?.utilization == 10 }
        model.setClaudeUsageEnabled(false)
        box.value = Account(usage: Usage(fiveHour: UsageWindow(utilization: 99, resetUnix: nil),
                                         sevenDay: nil, sevenDaySonnet: nil))
        try? await Task.sleep(nanoseconds: 200_000_000)   // several 0.05s ticks
        XCTAssertEqual(model.usage?.fiveHour?.utilization, 10,
                       "disabled provider must not pick up new fetch results")
    }

    @MainActor
    func testDisabledCodexUsageTearsDownServerAndPreservesCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 30, resetUnix: 1)),
            secondary: nil))
        model.setCodexUsageEnabled(false)
        XCTAssertEqual(model.codexState, .stopped)
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 30,
                       "disabling keeps the last known snapshot for the dimmed popover row")
    }

    @MainActor
    func testEnableCodexUsageAttemptsRespawnWithoutCrashing() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        model.setCodexUsageEnabled(false)
        model.setCodexUsageEnabled(true)
        XCTAssertTrue(model.codexUsageEnabled)
    }

    @MainActor
    func testRestartRestoresDisabledFlagWithoutFetching() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-usage-disabled-\(UInt32.random(in: 0..<UInt32.max)).json"
        let client1 = IPCClient(path: daemon.path); try client1.connect()
        let model1 = AppModel(
            client: client1,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { Account(usage: Usage(fiveHour: UsageWindow(utilization: 61, resetUnix: nil),
                                                 sevenDay: nil, sevenDaySonnet: nil)) },
            usageInterval: 0.05)
        await model1.start()
        _ = await eventually { model1.usage?.fiveHour?.utilization == 61 }
        model1.setClaudeUsageEnabled(false)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let model2 = AppModel(
            client: client2,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05),
            fetchAccount: { XCTFail("a disabled provider must not be fetched on restart"); return Account() },
            usageInterval: 0.05)
        await model2.start()
        XCTAssertFalse(model2.claudeUsageEnabled)
        XCTAssertEqual(model2.usage?.fiveHour?.utilization, 61)
        try? await Task.sleep(nanoseconds: 150_000_000)   // give the poller a chance to (wrongly) fire
    }
}

/// Mutable holder so the fetch closure can return changing values across ticks.
final class AccountBox: @unchecked Sendable { var value = Account() }
