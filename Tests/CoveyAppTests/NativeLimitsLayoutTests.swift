import AppKit
import SwiftUI
import XCTest
@testable import covey

@MainActor
final class NativeLimitsLayoutTests: XCTestCase {
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

    /// A GLM forecast adds one line under each window row and never changes
    /// the card's fixed width; the «Прогноз…» action link appears with it.
    func testLimitsOverlayGrowsWithGLMForecastLines() throws {
        _ = NSApplication.shared
        let quota = GLMQuota(plan: "max", limits: GLMLimits(
            fiveHours: GLMLimitWindow(total: 28000, used: 25200, remaining: 2800,
                                      usedPercent: 90, remainingPercent: 10,
                                      resetAt: 1_790_943_951_592),
            weekly: GLMLimitWindow(total: 140000, used: 7000, remaining: 133000,
                                   usedPercent: 5, remainingPercent: 95,
                                   resetAt: 1_791_529_507_983)))
        var forecast = GLMForecast()
        forecast.fiveHours = GLMWindowForecast(verdict: .overflow, projected: 30_000,
                                               remaining: 2_800, total: 28_000, resetAt: nil,
                                               exhaustionAt: Int64(Date().timeIntervalSince1970 * 1000)
                                                   + 110 * 60_000,
                                               headroomPercent: -18, rateCreditsPerHour: 0,
                                               agentMinutes: nil)
        forecast.weekly = GLMWindowForecast(verdict: .fits, projected: 0, remaining: 0, total: 0,
                                            resetAt: nil, exhaustionAt: nil,
                                            headroomPercent: 40, rateCreditsPerHour: 0,
                                            agentMinutes: nil)
        func content(_ glmForecast: GLMForecast?) -> some View {
            LimitsOverlayContent(
                usage: Usage(fiveHour: UsageWindow(utilization: 63, resetUnix: 1_800_000_000)),
                plan: "Max", error: nil,
                codexUsage: nil, codexPlan: nil,
                claudeUsageEnabled: true, codexUsageEnabled: true,
                onSetClaudeUsageEnabled: { _ in }, onSetCodexUsageEnabled: { _ in },
                glmQuota: quota, glmEnabled: true, glmError: nil,
                glmForecast: glmForecast,
                glmKeyStatus: .set, glmKeyValid: true,
                selectedProvider: .glm,
                tk: Tokens(.dark))
                .frame(width: 320)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.controlActiveState, .active)
        }
        func size(_ view: some View) -> CGSize {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            window.close()
            return fitting
        }

        let plain = size(content(nil))
        let forecasted = size(content(forecast))
        XCTAssertEqual(forecasted.width, 320, accuracy: 1)
        XCTAssertGreaterThan(forecasted.height, plain.height,
                             "two forecast lines (5h + 7d) must add height under the GLM windows")
        // Заголовок action link отражает состояние панели прогноза.
        XCTAssertEqual(overlayForecastToggleTitle(shown: false), "Прогноз…")
        XCTAssertEqual(overlayForecastToggleTitle(shown: true), "Скрыть прогноз")
    }
}
