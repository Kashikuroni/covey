import AppKit
import SwiftUI
import XCTest
@testable import covey

@MainActor
final class NativeLimitsLayoutTests: XCTestCase {
    func testNativePanelFitsCompactWindowInBothAppearances() throws {
        _ = NSApplication.shared
        let rows = limitsRows(
            usage: Usage(fiveHour: UsageWindow(utilization: 63, resetUnix: 1_800_000_000),
                         sevenDay: UsageWindow(utilization: 6, resetUnix: 1_800_100_000)),
            plan: "Max 5×", error: nil,
            codexUsage: CodexRateLimitsSnapshot(
                primary: LabeledWindow(label: "5h", window: UsageWindow(utilization: 100)),
                secondary: LabeledWindow(label: "7d", window: UsageWindow(utilization: 0))),
            codexPlan: "Pro",
            claudeEnabled: true, codexEnabled: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let content = NativeLimitsContent(rows: rows, connectionError: nil,
                                              settingsAvailable: true, settingsPending: false,
                                              menuBarEnabled: true, setEnabled: { _, _ in },
                                              setMenuBarEnabled: { _ in })
                .frame(width: 300)
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .active)

            let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            XCTAssertEqual(size.width, 300, accuracy: 1)
            XCTAssertGreaterThan(size.height, 200)
            XCTAssertLessThan(size.height, 360)
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/covey-native-panel-\(name).png"))
            window.close()
        }
    }

    /// The in-app popover renders the GLM section plus its API-key row in
    /// every key state without blowing up its fixed card width.
    func testLimitsOverlayRendersGLMSectionAndKeyRow() throws {
        _ = NSApplication.shared
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 25200, remaining: 2800,
                                      usedPercent: 90, remainingPercent: 10,
                                      resetAt: 1_790_943_951_592),
            weekly: GLMLimitWindow(total: 140000, used: 7000, remaining: 133000,
                                   usedPercent: 5, remainingPercent: 95,
                                   resetAt: 1_791_529_507_983)))
        for (name, status, valid) in [("valid", ProviderKeyStatus.set, true),
                                      ("invalid", ProviderKeyStatus.missing, false)] {
            let content = LimitsOverlayContent(
                usage: Usage(fiveHour: UsageWindow(utilization: 63, resetUnix: 1_800_000_000)),
                plan: "Max", error: nil,
                codexUsage: nil, codexPlan: nil,
                claudeUsageEnabled: true, codexUsageEnabled: true,
                onSetClaudeUsageEnabled: { _ in }, onSetCodexUsageEnabled: { _ in },
                glmQuota: quota, glmEnabled: true, glmError: nil,
                glmKeyStatus: status, glmKeyValid: valid,
                selectedProvider: .glm,
                tk: Tokens(.dark))
                .frame(width: 320)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.controlActiveState, .active)

            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            XCTAssertEqual(size.width, 320, accuracy: 1)
            XCTAssertGreaterThan(size.height, 300, "three provider sections + key row")
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/covey-overlay-glm-\(name).png"))
            window.close()
        }
    }
}
