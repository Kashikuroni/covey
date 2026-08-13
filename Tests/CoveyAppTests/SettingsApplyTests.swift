import XCTest
@testable import covey
import CoveyKit

private final class ProviderKeyIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String]
    private(set) var reads: [(account: String, onMainThread: Bool)] = []
    private(set) var writes: [(account: String, value: String, onMainThread: Bool)] = []
    private(set) var deletes: [(account: String, onMainThread: Bool)] = []

    init(stored: [String: String] = [:]) {
        self.stored = stored
    }

    func read(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        reads.append((account, Thread.isMainThread))
        return stored[account]
    }

    func write(_ account: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        writes.append((account, value, Thread.isMainThread))
        stored[account] = value
    }

    func delete(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        deletes.append((account, Thread.isMainThread))
        stored[account] = nil
    }
}

final class SettingsApplyTests: XCTestCase {
    @MainActor
    private func makeSettingsModel(
        _ daemon: TestDaemon,
        store: StateStore,
        readProviderKey: @escaping @Sendable (String) -> String? = {
            ProviderKeychain.read(account: $0)
        },
        writeProviderKey: @escaping @Sendable (String, String) -> Void = {
            ProviderKeychain.write(account: $0, value: $1)
        },
        deleteProviderKey: @escaping @Sendable (String) -> Void = {
            ProviderKeychain.delete(account: $0)
        }
    ) throws -> AppModel {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        return AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: store,
            fetchAccount: { Account() },
            usageInterval: 60,
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
        let probe = ProviderKeyIOProbe(stored: ["covey.provider.glm": "KEY"])
        let model = try makeSettingsModel(
            daemon,
            store: store,
            readProviderKey: { probe.read($0) },
            writeProviderKey: { probe.write($0, $1) },
            deleteProviderKey: { probe.delete($0) })

        XCTAssertEqual(model.providerKeyStatus(.glm), .checking)
        XCTAssertTrue(probe.reads.isEmpty, "render-readable status must be cache-only")

        await model.refreshProviderKeyStatuses([.glm])

        XCTAssertEqual(model.providerKeyStatus(.glm), .set)
        XCTAssertEqual(probe.reads.map { $0.account }, ["covey.provider.glm"])
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

        await model.setProviderKey(.glm, "KEY")

        XCTAssertEqual(model.providerKeyStatus(.glm), .set)
        XCTAssertEqual(probe.writes.map { $0.account }, ["covey.provider.glm"])
        XCTAssertEqual(probe.writes.map { $0.value }, ["KEY"])
        XCTAssertEqual(probe.writes.map { $0.onMainThread }, [false])

        await model.setProviderKey(.glm, "")

        XCTAssertEqual(model.providerKeyStatus(.glm), .missing)
        XCTAssertEqual(probe.deletes.map { $0.account }, ["covey.provider.glm"])
        XCTAssertEqual(probe.deletes.map { $0.onMainThread }, [false])
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
                                      claudeUsageEnabled: true, codexUsageEnabled: true,
                                      glmUsageEnabled: true))
    }

    @MainActor
    func testApplySettingsPersistsAllValuesInOneWrite() async throws {
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
            claudeUsageEnabled: false, codexUsageEnabled: false, glmUsageEnabled: false))
        store.flush()

        XCTAssertEqual(model.themeRaw, "light")
        XCTAssertFalse(model.vimMode)
        XCTAssertFalse(model.showSessions)
        XCTAssertFalse(model.showHeader)
        XCTAssertFalse(model.showFooter)
        XCTAssertEqual(model.usagePlacement, .left)
        XCTAssertFalse(model.claudeUsageEnabled)
        XCTAssertFalse(model.codexUsageEnabled)
        XCTAssertFalse(model.glmUsageEnabled)
        XCTAssertNil(model.modal)
        XCTAssertEqual(store.writeCount, writesBefore + 1)

        let saved = store.load()
        XCTAssertEqual(saved.theme, "light")
        XCTAssertEqual(saved.vimMode, false)
        XCTAssertEqual(saved.showSessions, false)
        XCTAssertEqual(saved.showHeader, false)
        XCTAssertEqual(saved.showFooter, false)
        XCTAssertEqual(saved.usagePlacement, "left")
        XCTAssertEqual(saved.claudeUsageEnabled, false)
        XCTAssertEqual(saved.codexUsageEnabled, false)
        XCTAssertEqual(saved.glmUsageEnabled, false)
    }

    @MainActor
    func testLegacyPersistedProviderDoesNotAffectSettings() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-settings-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        store.save(PersistedState(provider: "glm"))
        store.flush()
        let model = try makeSettingsModel(daemon, store: store)
        await model.start()

        XCTAssertEqual(model.settingsValues,
                       SettingsValues(theme: .dark, vimMode: true,
                                      showSessions: true, showHeader: true, showFooter: true,
                                      usagePlacement: .right,
                                      claudeUsageEnabled: true, codexUsageEnabled: true,
                                      glmUsageEnabled: true))
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
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
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
        model.setCodexState(.active(CodexAccount(type: "chatgpt", planType: "pro")))
        model.ingestCodexRateLimits(CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h",
                                   window: UsageWindow(utilization: 30, resetUnix: 1)),
            secondary: nil))
        var values = model.settingsValues
        values.codexUsageEnabled = false
        model.modal = .settings
        model.applySettings(values)
        XCTAssertEqual(model.codexState, .stopped)
        XCTAssertEqual(model.codexUsage?.primary?.window.utilization, 30)
    }
}
