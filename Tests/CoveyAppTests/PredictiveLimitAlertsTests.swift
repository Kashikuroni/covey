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
}
