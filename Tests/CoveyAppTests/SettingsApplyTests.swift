import XCTest
@testable import covey
import CoveyKit

final class SettingsApplyTests: XCTestCase {
    @MainActor
    private func makeSettingsModel(_ daemon: TestDaemon, store: StateStore) throws -> AppModel {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        return AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
            store: store,
            fetchAccount: { Account() },
            usageInterval: 60)
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
                                      claudeUsageEnabled: true, codexUsageEnabled: true))
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
            claudeUsageEnabled: false, codexUsageEnabled: false))
        store.flush()

        XCTAssertEqual(model.themeRaw, "light")
        XCTAssertFalse(model.vimMode)
        XCTAssertFalse(model.showSessions)
        XCTAssertFalse(model.showHeader)
        XCTAssertFalse(model.showFooter)
        XCTAssertEqual(model.usagePlacement, .left)
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
        XCTAssertEqual(saved.claudeUsageEnabled, false)
        XCTAssertEqual(saved.codexUsageEnabled, false)
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
