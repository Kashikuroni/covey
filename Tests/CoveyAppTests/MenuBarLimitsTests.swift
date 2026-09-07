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
}
