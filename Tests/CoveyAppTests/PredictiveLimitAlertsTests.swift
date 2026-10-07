import XCTest
import Foundation
import CoveyKit
@testable import covey

final class PredictiveLimitAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000)

    private func forecast(verdict: GLMForecastVerdict, etaMinutes: Double?, active: Bool = true,
                          resetInHours: Double = 5) -> GLMForecast {
        var f = GLMForecast()
        f.agents = [GLMAgentForecast(name: "a", external: false, active: active,
                                     isSidechainMarked: false, tokensPerHour: 1,
                                     creditsPerHour: 1, sharePercent: 100, budgetMinutes: nil)]
        let reset = Int64((now + resetInHours * 3600).timeIntervalSince1970 * 1000)
        f.fiveHours = GLMWindowForecast(verdict: verdict, projected: 900, remaining: 800,
                                        total: 1000, resetAt: reset, exhaustionAt: etaMinutes.map {
            Int64((now + $0 * 60).timeIntervalSince1970 * 1000)
        }, headroomPercent: 10, rateCreditsPerHour: 100, agentMinutes: nil)
        return f
    }

    func testOverflowFiresLevelZeroAlert() {
        let (alerts, marks) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90),
                                               config: GLMForecastConfigSection(), notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].windowKey, "predict:five")
        XCTAssertNotNil(marks["glm:predict:five"])
    }

    func testLadderEscalatesOncePerLevel() {
        let (a1, m1) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90),
                                        config: GLMForecastConfigSection(), notified: [:], now: now)
        XCTAssertEqual(a1.count, 1)
        // Та же ступень повторно — тишина.
        let (a2, _) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90),
                                       config: GLMForecastConfigSection(), notified: m1, now: now)
        XCTAssertEqual(a2.count, 0)
        // ETA < 60 мин → ступень 1 → алерт.
        let (a3, m3) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 50),
                                        config: GLMForecastConfigSection(), notified: m1, now: now)
        XCTAssertEqual(a3.count, 1)
        // Ступень 1 повторно — тишина.
        let (a4, _) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 45),
                                       config: GLMForecastConfigSection(), notified: m3, now: now)
        XCTAssertEqual(a4.count, 0)
    }

    func testCriticalLevelFifteenMinutes() {
        let (_, m1) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90),
                                       config: GLMForecastConfigSection(), notified: [:], now: now)
        _ = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 50),
                             config: GLMForecastConfigSection(), notified: m1, now: now)
        let (a3, _) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 10),
                                       config: GLMForecastConfigSection(), notified: m1, now: now)
        XCTAssertEqual(a3.count, 1, "перепрыг через ступень 1 тоже даёт один алерт — ступени монотонны")
        XCTAssertTrue(a3[0].title.contains("критично"))
    }

    func testIdleAndNoActiveAgentsAreSilent() {
        for f in [forecast(verdict: .idle, etaMinutes: 10),
                  forecast(verdict: .overflow, etaMinutes: 10, active: false)] {
            let (alerts, _) = predictiveAlerts(forecast: f, config: GLMForecastConfigSection(),
                                               notified: [:], now: now)
            XCTAssertEqual(alerts.count, 0)
        }
    }

    func testNewWindowResetsLadder() {
        let (_, m1) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90),
                                       config: GLMForecastConfigSection(), notified: [:], now: now)
        // Новое окно: resetAt другой → алерт снова на ступени 0.
        let (a2, _) = predictiveAlerts(forecast: forecast(verdict: .overflow, etaMinutes: 90,
                                                          resetInHours: 10),
                                       config: GLMForecastConfigSection(), notified: m1, now: now)
        XCTAssertEqual(a2.count, 1)
    }

    func testImminentDefaultsToTwentyMinutesWhenConfigAbsent() {
        // Спека §7: ключа imminentMinutes нет → дефолт 20 мин, а не «выключено».
        let (alerts, _) = predictiveAlerts(forecast: forecast(verdict: .tight, etaMinutes: 10),
                                           config: GLMForecastConfigSection(), notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts.first?.title.contains("исчерпание") ?? false)
    }

    func testImminentAlertFiresOncePerWindow() {
        // Вердикт fits, но ETA 10 мин < imminent (20) → один алерт, повторы молчат.
        let (a1, m1) = predictiveAlerts(forecast: forecast(verdict: .tight, etaMinutes: 10),
                                        config: GLMForecastConfigSection(imminentMinutes: 20),
                                        notified: [:], now: now)
        XCTAssertEqual(a1.count, 1)
        let (a2, _) = predictiveAlerts(forecast: forecast(verdict: .tight, etaMinutes: 5),
                                       config: GLMForecastConfigSection(imminentMinutes: 20),
                                       notified: m1, now: now)
        XCTAssertEqual(a2.count, 0)
    }

    /// Маркеры провайдеров не подавляют друг друга: одинаковый reset не
    /// схлопывает GLM- и Codex-ключи (префиксы glm:/codex:predict:).
    func testCodexMarkerDoesNotSuppressGLMAlert() {
        let config = GLMForecastConfigSection()
        var five = GLMWindowForecast(verdict: .overflow, projected: 110, remaining: -10,
                                     total: 100, resetAt: 1_800_003_600_000,
                                     exhaustionAt: 1_800_001_800_000,
                                     headroomPercent: -10, rateCreditsPerHour: 5,
                                     agentMinutes: nil)
        var f = GLMForecast()
        five.exhaustionAt = 1_800_001_800_000
        f.fiveHours = five
        f.agents = [GLMAgentForecast(name: "a", id: "a", external: false, active: true,
                                     isSidechainMarked: false, tokensPerHour: 10,
                                     creditsPerHour: 0, sharePercent: 100,
                                     budgetMinutes: nil)]
        let codexMarker = "codex:predict:codex:primary:1800003600000:overflow:0"
        let glm = predictiveAlerts(forecast: f, config: config,
                                   notified: [codexMarker: 1], now: Date())
        XCTAssertEqual(glm.alerts.count, 1,
                       "codex-маркер не гасит GLM-алерт того же окна")
        let codex = codexPredictiveAlerts(
            forecast: CodexForecast(windows: [CodexWindowForecast(
                bucketID: "codex", windowKey: .primary, label: "5h",
                verdict: .overflow, usedPercent: 90, projectedPercent: 110,
                projectedP50: nil, projectedP90: nil, headroomPercent: -10,
                resetAt: 1_800_003_600_000,
                exhaustionAt: Int64(Date().timeIntervalSince1970 * 1000) + 1_800_000,
                ratePercentPerHour: 10, sampleCount: 2, stale: false)], updatedAt: 1),
            config: config,
            notified: glm.notified, now: Date())
        XCTAssertEqual(codex.alerts.count, 1,
                       "GLM-маркеры не гасят codex-алерт")
    }
}
