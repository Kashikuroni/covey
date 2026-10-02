import XCTest
@testable import covey
import CoveyKit
import CoveydCore

private final class ProviderKeyIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String]
    private let writeSucceeds: Bool
    private let deleteSucceeds: Bool
    private(set) var reads: [(account: String, onMainThread: Bool)] = []
    private(set) var writes: [(account: String, value: String, onMainThread: Bool)] = []
    private(set) var deletes: [(account: String, onMainThread: Bool)] = []

    init(stored: [String: String] = [:],
         writeSucceeds: Bool = true,
         deleteSucceeds: Bool = true) {
        self.stored = stored
        self.writeSucceeds = writeSucceeds
        self.deleteSucceeds = deleteSucceeds
    }

    func read(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        reads.append((account, Thread.isMainThread))
        return stored[account]
    }

    func write(_ account: String, _ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writes.append((account, value, Thread.isMainThread))
        guard writeSucceeds else { return false }
        stored[account] = value
        return true
    }

    func delete(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        deletes.append((account, Thread.isMainThread))
        guard deleteSucceeds else { return false }
        stored[account] = nil
        return true
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class SettingsApplyTests: XCTestCase {
    func testProviderKeyLabelDistinguishesCheckingSetAndMissing() {
        XCTAssertEqual(providerKeyLabel(profile: .testProvider, status: .checking), "Checking…")
        XCTAssertEqual(providerKeyLabel(profile: .testProvider, status: .set), "Custom API key set ✓")
        XCTAssertEqual(providerKeyLabel(profile: .testProvider, status: .missing),
                       "Set Custom API key…")
    }

    func testProviderKeyMutationErrorPresentation() {
        XCTAssertEqual(
            providerKeyMutationError(.failure("storage failed")),
            "storage failed"
        )
        XCTAssertNil(providerKeyMutationError(.success))
    }

    @MainActor
    private func makeSettingsModel(
        _ daemon: TestDaemon,
        store: StateStore,
        readProviderKey: @escaping @Sendable (String) -> String? = {
            ProviderKeychain.read(account: $0)
        },
        writeProviderKey: @escaping @Sendable (String, String) -> Bool = {
            ProviderKeychain.write(account: $0, value: $1)
        },
        deleteProviderKey: @escaping @Sendable (String) -> Bool = {
            ProviderKeychain.delete(account: $0)
        }
    ) throws -> AppModel {
        let monitor = UsageMonitor(path: daemon.path + ".usage.json", legacyPath: daemon.path + ".legacy.json",
                                   fetchAccount: { Account() },
                                   usageInterval: 60, resolveCodex: { nil })
        daemon.attachUsageMonitor(monitor)
        let client = IPCClient(path: daemon.path)
        try client.connect()
        return AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: store,
            readProviderKey: readProviderKey,
            writeProviderKey: writeProviderKey,
            deleteProviderKey: deleteProviderKey)
    }

    @MainActor
    func testProviderKeyStatusReadsCacheAndRefreshesOffMainThread() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe(stored: ["covey.provider.custom": "KEY"])
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })

        XCTAssertEqual(model.providerKeyStatus(.testProvider), .checking)
        XCTAssertTrue(probe.reads.isEmpty, "render-readable status must be cache-only")

        await model.refreshProviderKeyStatuses([.testProvider])

        XCTAssertEqual(model.providerKeyStatus(.testProvider), .set)
        XCTAssertEqual(probe.reads.map { $0.account }, ["covey.provider.custom"])
        XCTAssertEqual(probe.reads.map { $0.onMainThread }, [false])
    }

    @MainActor
    func testProviderKeySaveAndClearRunOffMainThreadAndUpdateCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe()
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })

        let saveResult = await model.setProviderKey(.testProvider, "KEY")
        XCTAssertEqual(saveResult, .success)

        XCTAssertEqual(model.providerKeyStatus(.testProvider), .set)
        XCTAssertEqual(probe.writes.map { $0.account }, ["covey.provider.custom"])
        XCTAssertEqual(probe.writes.map { $0.value }, ["KEY"])
        XCTAssertEqual(probe.writes.map { $0.onMainThread }, [false])
        XCTAssertEqual(probe.reads.map { $0.account }, ["covey.provider.custom"])
        XCTAssertEqual(probe.reads.map { $0.onMainThread }, [false])

        let clearResult = await model.setProviderKey(.testProvider, "")
        XCTAssertEqual(clearResult, .success)

        XCTAssertEqual(model.providerKeyStatus(.testProvider), .missing)
        XCTAssertEqual(probe.deletes.map { $0.account }, ["covey.provider.custom"])
        XCTAssertEqual(probe.deletes.map { $0.onMainThread }, [false])
        XCTAssertEqual(probe.reads.map { $0.account },
                       ["covey.provider.custom", "covey.provider.custom"])
        XCTAssertEqual(probe.reads.map { $0.onMainThread }, [false, false])
    }

    @MainActor
    func testProviderKeySaveReportsWriterFailureWithoutSettingCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe(writeSucceeds: false)
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })

        let result = await model.setProviderKey(.testProvider, "KEY")

        XCTAssertEqual(
            result,
            .failure("Couldn’t save API key. Check Keychain access and try again."))
        XCTAssertNotEqual(model.providerKeyStatus(.testProvider), .set)
    }

    @MainActor
    func testFailedProviderKeyUpdatePreservesExistingKeyAndSetStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe(
            stored: ["covey.provider.custom": "OLD"],
            writeSucceeds: false
        )
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })
        await model.refreshProviderKeyStatuses([.testProvider])

        let result = await model.setProviderKey(.testProvider, "NEW")

        XCTAssertEqual(
            result,
            .failure("Couldn’t save API key. Check Keychain access and try again."))
        XCTAssertEqual(model.providerKeyStatus(.testProvider), .set)
        XCTAssertEqual(probe.read("covey.provider.custom"), "OLD")
    }

    @MainActor
    func testProviderKeySaveReportsReadBackMismatchWithoutSettingCache() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { _ in nil },
            writeProviderKey: { _, _ in true },
            deleteProviderKey: { _ in true })

        let result = await model.setProviderKey(.testProvider, "KEY")

        XCTAssertEqual(
            result,
            .failure("Couldn’t save API key. Check Keychain access and try again."))
        XCTAssertNotEqual(model.providerKeyStatus(.testProvider), .set)
    }

    @MainActor
    func testProviderKeyClearReportsDeleteFailureAndKeepsSetStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe(
            stored: ["covey.provider.custom": "KEY"],
            deleteSucceeds: false
        )
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })
        await model.refreshProviderKeyStatuses([.testProvider])

        let result = await model.setProviderKey(.testProvider, "")

        XCTAssertEqual(
            result,
            .failure("Couldn’t save API key. Check Keychain access and try again."))
        XCTAssertEqual(model.providerKeyStatus(.testProvider), .set)
        XCTAssertEqual(probe.read("covey.provider.custom"), "KEY")
    }

    @MainActor
    func testProviderKeyClearReportsReadBackStillPresentAndKeepsSetStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(
            path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
            debounce: 0.05)
        let probe = ProviderKeyIOProbe(stored: ["covey.provider.custom": "KEY"])
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { _ in true })
        await model.refreshProviderKeyStatuses([.testProvider])

        let result = await model.setProviderKey(.testProvider, "")

        XCTAssertEqual(
            result,
            .failure("Couldn’t save API key. Check Keychain access and try again."))
        XCTAssertEqual(model.providerKeyStatus(.testProvider), .set)
        XCTAssertEqual(probe.read("covey.provider.custom"), "KEY")
    }

    @MainActor
    func testOpenSettingsDoesNotReplaceAnotherModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        model.openSettings()
        XCTAssertEqual(model.modal, .settings)
        XCTAssertEqual(model.modal?.id, "settings")
        model.modal = .recent
        model.openSettings()
        XCTAssertEqual(model.modal, .recent)
    }

    @MainActor
    func testSettingsSnapshotMatchesLiveModel() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        XCTAssertEqual(model.settingsValues,
                       SettingsValues(theme: .dark, vimMode: true,
                                      showSessions: true, showHeader: true, showFooter: true,
                                      usagePlacement: .right,
                                      claudeUsageEnabled: true, codexUsageEnabled: true, glmUsageEnabled: true))
    }

    @MainActor
    func testApplySettingsPersistsLocalValuesAndAcknowledgesDaemonPreferences() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        store.flush()
        let writesBefore = store.writeCount
        model.modal = .settings
        model.applySettings(SettingsValues(
            theme: .light, vimMode: false,
            showSessions: false, showHeader: false, showFooter: false,
            usagePlacement: .left,
            claudeUsageEnabled: false, codexUsageEnabled: false, glmUsageEnabled: true))
        store.flush()

        XCTAssertEqual(model.themeRaw, "light")
        XCTAssertFalse(model.vimMode)
        XCTAssertFalse(model.showSessions)
        XCTAssertFalse(model.showHeader)
        XCTAssertFalse(model.showFooter)
        XCTAssertEqual(model.usagePlacement, .left)
        let acknowledged = await eventually {
            !model.claudeUsageEnabled && !model.codexUsageEnabled && !model.usageSettingsPending
        }
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(model.claudeUsageEnabled)
        XCTAssertFalse(model.codexUsageEnabled)
        XCTAssertNil(model.modal)
        XCTAssertEqual(store.writeCount, writesBefore + 1)

        let saved = store.load()
        XCTAssertEqual(saved.theme, "light")
        XCTAssertEqual(saved.vimMode, false)
        XCTAssertEqual(saved.showSessions, false)
        XCTAssertEqual(saved.showHeader, false)
        XCTAssertEqual(saved.showFooter, false)
        XCTAssertEqual(saved.usagePlacement, "left")
        XCTAssertNil(saved.claudeUsageEnabled)
        XCTAssertNil(saved.codexUsageEnabled)
    }

    @MainActor
    func testLegacyPersistedProviderDoesNotAffectSettings() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        store.save(PersistedState(provider: "custom"))
        store.flush()
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()

        XCTAssertEqual(model.settingsValues,
                       SettingsValues(theme: .dark, vimMode: true,
                                      showSessions: true, showHeader: true, showFooter: true,
                                      usagePlacement: .right,
                                      claudeUsageEnabled: true, codexUsageEnabled: true, glmUsageEnabled: true))
    }

    @MainActor
    func testApplyingUnchangedSettingsOnlyClosesSheet() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        store.flush()
        let writesBefore = store.writeCount
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        _ = await eventually { model.codexState == .active(CodexAccount(type: "chatgpt", planType: "pro")) }
        model.modal = .settings
        model.applySettings(model.settingsValues)
        store.flush()
        XCTAssertNil(model.modal)
        XCTAssertEqual(store.writeCount, writesBefore)
        XCTAssertEqual(model.codexState,
                       .active(CodexAccount(type: "chatgpt", planType: "pro")))
    }

    @MainActor
    func testSavedThemeChangeOffersExistingBusyAgentFollowUpAfterDismissal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        // No monitor tick -> no status -> the agent counts as busy.
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        var values = model.settingsValues
        values.theme = .light
        model.modal = .settings
        model.applySettings(values)
        XCTAssertNil(model.toast)
        XCTAssertNil(model.modal)
        model.modalDidDismiss()
        XCTAssertTrue(model.toast?.contains("keep old theme") == true)
        XCTAssertNotEqual(model.modal, .settings)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testSavedThemeChangeWaitsForDismissalBeforeIdleRestartOffer() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["agent"] == .idle
        }
        var values = model.settingsValues
        values.theme = .light
        model.modal = .settings
        model.applySettings(values)
        XCTAssertNil(model.modal, "settings must close before presenting the follow-up")
        model.modalDidDismiss()
        XCTAssertEqual(model.modal, .themeRestart)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testBatchDisableCodexStopsServerStateAndKeepsCachedUsage() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let store = StateStore(path: "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json",
                               debounce: 0.05)
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()
        daemon.usageMonitor!.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        daemon.usageMonitor!.ingestRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h",
                                   window: UsageWindow(utilization: 30, resetUnix: 1)),
            secondary: nil))
        var values = model.settingsValues
        values.codexUsageEnabled = false
        model.modal = .settings
        model.applySettings(values)
        let disabled = await eventually { !model.codexUsageEnabled && model.codexUsage?.primary?.window.utilization == 30 }
        XCTAssertTrue(disabled)
        XCTAssertEqual(model.codexState, .stopped)
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 30)
    }
}
