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
}
