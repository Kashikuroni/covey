import XCTest
@testable import covey
import CoveyKit
import CoveydCore

final class AppModelUsageTests: XCTestCase {
    @MainActor
    private func makeUsageModel(_ daemon: TestDaemon,
                                fetch: @escaping () async -> Account,
                                interval: TimeInterval = 0.05) throws -> AppModel {
        let monitor = UsageMonitor(path: daemon.path + ".usage.json", legacyPath: daemon.path + ".legacy.json",
                                   fetchAccount: fetch,
                                   usageInterval: interval, resolveCodex: { nil })
        daemon.attachUsageMonitor(monitor)
        monitor.start()
        return try makeModel(daemon).0
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
        let monitor = UsageMonitor(path: daemon.path + ".usage.json", legacyPath: daemon.path + ".legacy.json",
                                   fetchAccount: { acc },
                                   usageInterval: 0.05, resolveCodex: { nil })
        daemon.attachUsageMonitor(monitor)
        monitor.start()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05))
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
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 40, resetUnix: 2))))
        // Partial update: only primary — secondary must survive.
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 55, resetUnix: 3)),
            secondary: nil))
        _ = await eventually { model.codexPlan == "Pro" && model.codexUsage?.primary?.window.utilization != nil }
        XCTAssertEqual(model.codexPlan, "Pro")
        let merged = await eventually { model.codexUsage?.primary?.window.utilization == 55 }
        XCTAssertTrue(merged)
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 55)
        XCTAssertEqual(model.codexUsage?.secondary?.window.utilization, 40)
    }

    @MainActor
    func testCodexLimitCrossingPersistsPrefixedMarker() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        _ = try makeUsageModel(daemon, fetch: { Account() })
        let statePath = "\(NSTemporaryDirectory())covey-codex-\(UInt32.random(in: 0..<UInt32.max)).json"
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05))
        await model.start()
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "plus")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
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
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: nil))
        daemon.usageMonitor!.setCodexState(.stopped)
        _ = await eventually { model.codexPlan == "Pro" && model.codexUsage?.primary?.window.utilization != nil }
        XCTAssertEqual(model.codexPlan, "Pro")
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 12)
    }

    @MainActor
    func testSetCodexStateUnauthedClearsCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try makeUsageModel(daemon, fetch: { Account() })
        await model.start()
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 12, resetUnix: 1)),
            secondary: nil))
        _ = await eventually { model.codexUsage != nil }
        daemon.usageMonitor!.setCodexState(.unauthed)
        let cleared = await eventually { model.codexUsage == nil && model.codexPlan == nil }
        XCTAssertTrue(cleared)
        XCTAssertNil(model.codexPlan)
        XCTAssertNil(model.codexUsage)
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
        _ = await eventually { !model.claudeUsageEnabled && !model.usageSettingsPending }
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
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 30, resetUnix: 1)),
            secondary: nil))
        model.setCodexUsageEnabled(false)
        _ = await eventually { !model.codexUsageEnabled && model.codexUsage != nil }
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
        _ = await eventually { !model.codexUsageEnabled && !model.usageSettingsPending }
        model.setCodexUsageEnabled(true)
        _ = await eventually { model.codexUsageEnabled && !model.usageSettingsPending }
        XCTAssertTrue(model.codexUsageEnabled)
    }

    @MainActor
    func testDaemonRestartRestoresCacheAndDisabledPreference() async throws {
        let first = try TestDaemon(); defer { first.stop() }
        let model = try makeUsageModel(first, fetch: {
            Account(usage: Usage(fiveHour: UsageWindow(utilization: 61, resetUnix: nil),
                                 sevenDay: nil, sevenDaySonnet: nil), plan: "Max")
        })
        await model.start()
        _ = await eventually { model.usage?.fiveHour?.utilization == 61 }
        model.setClaudeUsageEnabled(false)
        let disabled = await eventually { !model.claudeUsageEnabled && !model.usageSettingsPending }
        XCTAssertTrue(disabled)
        first.usageMonitor!.stop()

        let second = try TestDaemon(); defer { second.stop() }
        let restoredMonitor = UsageMonitor(path: first.path + ".usage.json", legacyPath: second.path + ".legacy.json",
            fetchAccount: { XCTFail("disabled provider fetched after daemon restart"); return Account() },
            usageInterval: 0.05, resolveCodex: { nil })
        second.attachUsageMonitor(restoredMonitor)
        restoredMonitor.start()
        let restored = try makeModel(second).0
        await restored.start()
        XCTAssertFalse(restored.claudeUsageEnabled)
        XCTAssertEqual(restored.usage?.fiveHour?.utilization, 61)
        XCTAssertEqual(restored.plan, "Max")
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    func testCachedUsageSurvivesUIRestartAndEmptyDaemonPolls() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(usage: Usage(fiveHour: UsageWindow(utilization: 61, resetUnix: nil),
                                         sevenDay: nil, sevenDaySonnet: nil), plan: "Max")
        let first = try makeUsageModel(daemon, fetch: { box.value })
        await first.start()
        let loaded = await eventually { first.usage?.fiveHour?.utilization == 61 }
        XCTAssertTrue(loaded)
        box.value = Account()
        let second = try makeModel(daemon).0
        await second.start()
        XCTAssertEqual(second.usage?.fiveHour?.utilization, 61)
        XCTAssertEqual(second.plan, "Max")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(second.usage?.fiveHour?.utilization, 61)
    }

    @MainActor
    func testTwoModelsShareUpdatesAndAcknowledgedSettings() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(plan: "Pro")
        let first = try makeUsageModel(daemon, fetch: { box.value })
        let second = try makeModel(daemon).0
        await first.start()
        await second.start()
        let initial = await eventually { first.plan == "Pro" && second.plan == "Pro" }
        XCTAssertTrue(initial)
        box.value = Account(plan: "Max")
        let updated = await eventually { first.plan == "Max" && second.plan == "Max" }
        XCTAssertTrue(updated)
        first.setClaudeUsageEnabled(false)
        let disabled = await eventually { !first.claudeUsageEnabled && !second.claudeUsageEnabled }
        XCTAssertTrue(disabled)
    }

    @MainActor
    func testUnsupportedDaemonPreservesSettingsAndReportsError() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "existing-session")
        defer { daemon.registry.kill(name: "existing-session") }
        let model = try makeModel(daemon).0
        await model.start()
        XCTAssertNotNil(model.usageConnectionError)
        model.setClaudeUsageEnabled(false)
        let finished = await eventually { !model.usageSettingsPending }
        XCTAssertTrue(finished)
        XCTAssertTrue(model.claudeUsageEnabled)
        XCTAssertNotNil(model.usageConnectionError)
        XCTAssertEqual(daemon.registry.list().map(\.name), ["existing-session"])
    }

    @MainActor
    func testReconnectReceivesLatestDaemonSnapshot() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let box = AccountBox()
        box.value = Account(plan: "Pro")
        _ = try makeUsageModel(daemon, fetch: { box.value })
        let (model, client) = try makeModel(daemon)
        await model.start()
        _ = await eventually { model.plan == "Pro" }
        client.close()
        let disconnected = await eventually { !model.connected && model.usageConnectionError != nil }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(model.plan, "Pro", "disconnect retains the last received snapshot")
        box.value = Account(plan: "Max")
        let collected = await eventually { daemon.usageMonitor?.snapshot.plan == "Max" }
        XCTAssertTrue(collected, "daemon keeps collecting while UI is disconnected")
        await model.reconnect()
        let reconnected = await eventually { model.plan == "Max" && model.usageConnectionError == nil }
        XCTAssertTrue(reconnected)
    }

}

/// Mutable holder so the fetch closure can return changing values across ticks.
final class AccountBox: @unchecked Sendable { var value = Account() }
