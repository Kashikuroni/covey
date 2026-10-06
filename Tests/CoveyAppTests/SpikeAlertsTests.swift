import XCTest
import Foundation
import CoveyKit
@testable import covey

/// Спайк-детект (этап 3): активная сессия с большим абсолютным темпом жжёт
/// в multiplier раз больше недельной EMA-ставки → алерт; cooldown гасит
/// повторы; мелкий темп и некалиброванная неделя не шумят.
final class SpikeAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func forecast(ema: Double, verdict: GLMForecastVerdict = .fits,
                          agentTokens: Double, agentCredits: Double,
                          active: Bool = true) -> GLMForecast {
        var f = GLMForecast()
        f.weekly = GLMWindowForecast(verdict: verdict, projected: 0, remaining: 1000,
                                     total: 1000, resetAt: nil, exhaustionAt: nil,
                                     headroomPercent: 50, rateCreditsPerHour: ema,
                                     agentMinutes: nil)
        f.agents = [GLMAgentForecast(name: "fix-auth", id: "uuid-1", external: false,
                                     active: active, isSidechainMarked: false,
                                     tokensPerHour: agentTokens, creditsPerHour: agentCredits,
                                     sharePercent: 100, budgetMinutes: nil)]
        return f
    }

    func testSpikeFiresAtMultiplierWithRealBurn() {
        // EMA 100 cr/h, агент 1000 cr/h (10×) и 12M ток/ч → алерт.
        let (alerts, marks) = spikeAlerts(forecast: forecast(ema: 100, agentTokens: 12_000_000,
                                                             agentCredits: 1000),
                                          notified: [:], now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].title.contains("fix-auth"))
        XCTAssertTrue(alerts[0].body.contains("10.0×"))
        XCTAssertNotNil(marks["glm:spike:uuid-1"])
    }

    func testNormalPaceIsSilent() {
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 1000, agentTokens: 12_000_000,
                                                         agentCredits: 1000),
                                      notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty, "ratio 1× — не всплеск")
    }

    func testSmallBurnIsSilentEvenAtHighRatio() {
        // 20× от почти нулевой EMA, но токенов мало — шум, не спайк.
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 1, agentTokens: 500_000,
                                                         agentCredits: 20),
                                      notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testNoBaselineIsSilent() {
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 0, agentTokens: 12_000_000,
                                                         agentCredits: 1000),
                                      notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty, "некалиброванная неделя — базы нет")
    }

    func testCalibratingWeeklyIsSilent() {
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 100, verdict: .calibrating,
                                                         agentTokens: 12_000_000,
                                                         agentCredits: 1000),
                                      notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testCooldownSuppressesRepeatAndRefiresAfter() {
        let f = forecast(ema: 100, agentTokens: 12_000_000, agentCredits: 1000)
        let first = spikeAlerts(forecast: f, notified: [:], now: now)
        XCTAssertEqual(first.alerts.count, 1)
        // Через минуту — молчит (cooldown 30 мин).
        let soon = spikeAlerts(forecast: f, notified: first.notified,
                               now: now.addingTimeInterval(60))
        XCTAssertTrue(soon.alerts.isEmpty)
        // Через 31 минуту — снова алерт.
        let later = spikeAlerts(forecast: f, notified: first.notified,
                                now: now.addingTimeInterval(31 * 60))
        XCTAssertEqual(later.alerts.count, 1)
    }

    func testZeroMultiplierDisables() {
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 100, agentTokens: 12_000_000,
                                                         agentCredits: 1000),
                                      notified: [:], now: now, multiplier: 0)
        XCTAssertTrue(alerts.isEmpty, "0 в конфиге выключает спайк-алерты")
    }

    func testInactiveAgentIgnored() {
        let (alerts, _) = spikeAlerts(forecast: forecast(ema: 100, agentTokens: 12_000_000,
                                                         agentCredits: 1000, active: false),
                                      notified: [:], now: now)
        XCTAssertTrue(alerts.isEmpty)
    }
}
