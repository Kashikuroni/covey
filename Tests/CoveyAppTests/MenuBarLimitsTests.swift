import XCTest
import CoveyKit
import CoveydCore
@testable import covey

final class MenuBarLimitsTests: XCTestCase {
    func testTitleShowsOneWindowPerProvider() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 42.4, resetUnix: nil),
                          sevenDay: UsageWindow(utilization: 90, resetUnix: nil),
                          sevenDaySonnet: nil)
        let codex = CodexRateLimitsSnapshot(
            primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 8, resetUnix: nil)),
            secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 18, resetUnix: nil)))
        XCTAssertEqual(menuBarLimitsTitle(usage: usage, codexUsage: codex,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude 5h 42% · GPT 5h 8%",
                       "outside the blink phase every provider shows its 5h window")
    }

    func testTitleBlinksARed7dWindowIn() {
        let usage = Usage(fiveHour: UsageWindow(utilization: 42.4, resetUnix: nil),
                          sevenDay: UsageWindow(utilization: 90, resetUnix: nil),
                          sevenDaySonnet: nil)
        XCTAssertEqual(menuBarLimitsTitle(usage: usage, codexUsage: nil,
                                          now: Date(timeIntervalSince1970: 10)),
                       "Claude 7d 90% · GPT —")
    }

    func testMissingDataKeepsMenuBarEntryAvailable() {
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude — · GPT —")
    }

    func testTitleAppendsGLMOnlyWhenItHasData() {
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 21000, remaining: 7000,
                                      usedPercent: 75, remainingPercent: 25,
                                      resetAt: 1_790_943_951_592)))
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: quota, glmEnabled: true,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude — · GPT — · GLM 5h 75%")
        // Enabled but empty (or disabled) keeps the two-slot title.
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: nil, glmEnabled: true,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude — · GPT —")
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: quota, glmEnabled: false,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude — · GPT —")
    }

    func testTitleShowsLoneGLMWeeklyWindow() {
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            weekly: GLMLimitWindow(total: 140000, used: 5695, remaining: 134304,
                                   usedPercent: 4, remainingPercent: 96,
                                   resetAt: 1_791_529_507_983)))
        XCTAssertEqual(menuBarLimitsTitle(usage: nil, codexUsage: nil,
                                          glmQuota: quota, glmEnabled: true,
                                          now: Date(timeIntervalSince1970: 100)),
                       "Claude — · GPT — · GLM 7d 4%",
                       "a lone 7d window keeps the slot permanently")
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
