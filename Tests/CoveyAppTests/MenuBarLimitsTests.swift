import XCTest
import CoveyKit
import CoveydCore
@testable import covey

final class MenuBarLimitsTests: XCTestCase {
    func testTitleShowsClaudeShortWindowAndMostUsedCodexWindow() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 42.4, resetUnix: nil),
                          sevenDay: UsageWindow(utilization: 90, resetUnix: nil),
                          sevenDaySonnet: nil)
        let codex = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: nil)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 18, resetUnix: nil)))
        XCTAssertEqual(menuBarLimitsTitle(usage: usage, codexUsage: codex),
                       "Claude 42% · GPT 18%")
    }

    func testMissingDataKeepsMenuBarEntryAvailable() {
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil),
                       "Claude — · GPT —")
    }

    func testTitleAppendsGLMOnlyWhenItHasData() {
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 21000, remaining: 7000,
                                      usedPercent: 75, remainingPercent: 25,
                                      resetAt: 1_790_943_951_592)))
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: quota, glmEnabled: true),
                       "Claude — · GPT — · GLM 75%")
        // Enabled but empty (or disabled) keeps the two-slot title.
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: nil, glmEnabled: true),
                       "Claude — · GPT —")
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: quota, glmEnabled: false),
                       "Claude — · GPT —")
    }

    @MainActor
    func testMenuBarPreferenceDefaultsOffAndSurvivesRestart() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = NSTemporaryDirectory() + "covey-menu-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path)
        let monitor = UsageMonitor(path: daemon.path + ".usage.json", legacyPath: daemon.path + ".legacy.json",
                                   fetchAccount: { Account() },
                                   resolveCodex: { nil })
        try monitor.setEnabled(.codex, enabled: false)
        daemon.attachUsageMonitor(monitor)
        func makeModel() throws -> AppModel {
            let client = IPCClient(path: daemon.path)
            try client.connect()
            return AppModel(client: client, makeClient: {
                let next = IPCClient(path: daemon.path)
                try next.connect()
                return next
            }, store: store)
        }
        let model = try makeModel()
        await model.start()
        XCTAssertFalse(model.menuBarLimitsEnabled)
        model.setMenuBarLimitsEnabled(true)
        store.flush()
        XCTAssertEqual(store.load().menuBarLimitsEnabled, true)

        let restored = try makeModel()
        await restored.start()
        XCTAssertTrue(restored.menuBarLimitsEnabled)
        XCTAssertFalse(restored.codexUsageEnabled,
                       "Showing limits must not change provider polling preferences")
        restored.setMenuBarLimitsEnabled(false)
        store.flush()
        XCTAssertEqual(store.load().menuBarLimitsEnabled, false)
    }

    /// Кандидат на подъём при клике по статус-айтему: рабочее окно с титульным
    /// стилем; служебные (статус-бар — это NSPanel, безтитульные) пропускаются.
    @MainActor
    func testActivationWindowSkipsAuxiliaryWindows() throws {
        _ = NSApplication.shared
        let auxiliary = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 10, height: 10),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        let main = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        // close() с дефолтным isReleasedWhenClosed перевыпустит окно под
        // ногами у аллокатора памяти XCTest — держим окна живыми до конца.
        auxiliary.isReleasedWhenClosed = false
        main.isReleasedWhenClosed = false
        defer { auxiliary.close(); main.close() }
        XCTAssertEqual(limitsActivationWindow(from: [auxiliary, main]), main)
        XCTAssertNil(limitsActivationWindow(from: [auxiliary]))
    }

    /// Действие клика по статус-айтему совпадает с ⌘L: режим limits в главном
    /// окне (та же команда Show Limits Detail) и обратное закрытие.
    @MainActor
    func testStatusBarClickOpensLimitsOverlay() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        let main = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        defer { main.close() }
        main.makeKeyAndOrderFront(nil)

        XCTAssertNotEqual(model.inputMode, .limits)
        openLimitsDetailFromStatusBar(model: model)
        XCTAssertEqual(model.inputMode, .limits)
        model.apply(.closeOverlay)
        XCTAssertEqual(model.inputMode, .normal)
    }
}
