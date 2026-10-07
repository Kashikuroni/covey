import XCTest
import CoveyKit
@testable import covey

/// Чистые helpers миграции Forecast UI на провайдер-нейтральную
/// `ForecastAnalytics`: какие секции показывать, строки таблицы сессий с
/// source-бейджами, GLM-кредиты только по GLM-моделям.
final class ForecastAnalyticsPresentationTests: XCTestCase {
    private var analyticsWithGPT: ForecastAnalytics {
        var analytics = ForecastAnalytics()
        analytics.models = [GLMModelUsage(model: "gpt-6-sol",
                                          window: GLMTokenUsage(input: 100),
                                          lastHour: GLMTokenUsage(input: 100))]
        analytics.sessions = [ForecastSessionUsage(id: "codex:s1", name: "~/work/app",
                                                   source: .codex, external: true,
                                                   active: true, tokensPerHour: 500)]
        return analytics
    }

    // MARK: - content state

    func testAnalyticsGridVisibleWhenGLMMonitoringIsOff() {
        let state = forecastContentState(glmEnabled: false, glmForecast: nil,
                                         analytics: analyticsWithGPT)
        XCTAssertTrue(state.showsAnalytics)
        XCTAssertTrue(state.showsGPTModels)
        XCTAssertFalse(state.showsGLMWindows)
        XCTAssertTrue(state.showsGLMOff)
    }

    func testGLMOnboardingShowsWithEmptyAnalytics() {
        let state = forecastContentState(glmEnabled: true, glmAPIKeyMissing: true,
                                         glmForecast: nil, analytics: ForecastAnalytics())
        XCTAssertTrue(state.showsGLMOnboarding)
        XCTAssertFalse(state.showsAnalytics, "пустая аналитика — только onboarding-карточка")
        XCTAssertFalse(state.showsGLMWindows)
    }

    func testGLMWaitingCardShowsUntilFirstPoll() {
        var forecast = GLMForecast()
        forecast.tokensPerHour = 1
        let state = forecastContentState(glmEnabled: true, glmForecast: forecast,
                                         analytics: ForecastAnalytics())
        XCTAssertTrue(state.showsGLMWaiting, "GLM включён, окон ещё нет — карточка ожидания")
        XCTAssertFalse(state.showsGLMWindows)
    }

    func testWindowsAndAnalyticsCoexist() {
        var forecast = GLMForecast()
        forecast.fiveHours = GLMWindowForecast(verdict: .fits, projected: 1, remaining: 1,
                                               total: 10, resetAt: nil, exhaustionAt: nil,
                                               headroomPercent: 90,
                                               rateCreditsPerHour: 1, agentMinutes: nil)
        let state = forecastContentState(glmEnabled: true, glmForecast: forecast,
                                         analytics: analyticsWithGPT)
        XCTAssertTrue(state.showsGLMWindows)
        XCTAssertTrue(state.showsAnalytics)
    }

    // MARK: - session rows

    private var gptSession: ForecastSessionUsage {
        ForecastSessionUsage(id: "codex:s1", name: "~/work/app", source: .codex,
                             external: true, active: true, tokensPerHour: 500)
    }

    func testGPTSessionDoesNotShowGLMCreditsOrBudget() {
        let row = sessionPresentation(gptSession)
        XCTAssertEqual(row.credits, "—")
        XCTAssertEqual(row.budget, "—")
        XCTAssertEqual(row.source, "Codex")
    }

    func testClaudeSessionShowsSourceBadge() {
        var session = gptSession
        session.source = .claudeCode
        session.creditsPerHour = 42.5
        session.budgetMinutes = 90
        let row = sessionPresentation(session)
        XCTAssertEqual(row.source, "Claude Code")
        XCTAssertEqual(row.credits, "42.5")
        XCTAssertEqual(row.budget, "1h 30m")
    }

    func testAgentRowsCarryShareAndExternalTag() {
        var mixed = analyticsWithGPT
        mixed.sessions.append(ForecastSessionUsage(id: "glm-live", name: "work",
                                                   source: .claudeCode, external: false,
                                                   active: true, tokensPerHour: 1500))
        let rows = agentRows(mixed.sessions)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == "glm-live" }?.sharePercent ?? 0, 75,
                       accuracy: 0.01, "1500 из 2000")
        XCTAssertEqual(rows.first { $0.id == "codex:s1" }?.sharePercent ?? 0, 25,
                       accuracy: 0.01)
        XCTAssertEqual(Set(rows.map(\.source)), [.codex, .claudeCode])
    }

    // MARK: - session costs credits

    func testSessionCostsCreditsUseOnlyGLMModels() {
        var usage = [String: GLMTokenUsage]()
        usage["gpt-6-sol"] = GLMTokenUsage(input: 10_000, output: 10_000)
        usage["glm-5.3"] = GLMTokenUsage(input: 100, output: 100)
        let entry = ForecastSessionCostEntry(
            record: SessionCostRecord(firstSeen: 1, lastSeen: 2,
                                      byModel: ["gpt-6-sol": 20_000, "glm-5.3": 200],
                                      external: true, cwd: nil, usage: usage),
            name: "~/work/app", source: .codex, live: true)
        XCTAssertEqual(sessionEstimatedGLMCredits(entry, factor: 0.5), "~100 cr",
                       "фактор множит только GLM-токены (200 × 0.5)")
        XCTAssertEqual(sessionEstimatedGLMCredits(entry, factor: nil), "—")
    }

    // MARK: - dollar spend

    func testGPTModelPriceBillsUncachedAndCachedSeparately() {
        let now = Date()
        var hour = GLMHourUsage(t: Int64(now.timeIntervalSince1970 * 1000), usage: [:])
        hour.usage["gpt-6-sol"] = GLMTokenUsage(input: 100, output: 0,
                                                cacheCreation: 0, cacheRead: 60)
        let prices = ModelPrices(input: 1.0, cachedRead: 0.1, cacheWrite: 0, output: 0)
        func cost(_ model: String, _ usage: GLMTokenUsage) -> Double? {
            usage.input / 1_000_000 * prices.input
                + usage.cacheRead / 1_000_000 * prices.cachedRead
                + usage.cacheCreation / 1_000_000 * prices.cacheWrite
                + usage.output / 1_000_000 * prices.output
        }
        let s = SpendCard.series(hourly: [hour], daily: [], range: .day,
                                 cost: cost, now: now)
        // Миллионные цены: 100/1M×1 + 60/1M×0.1 → в единицах Million-токенов.
        XCTAssertEqual(s.total ?? 0, 0.000106, accuracy: 1e-9,
                       "uncached input и cached input считаются по своим ставкам")
    }

    // MARK: - agent icon

    func testSourceMapsToAgentIconCommand() {
        XCTAssertEqual(agentIconCommand(for: .claudeCode), "claude")
        XCTAssertEqual(agentIconCommand(for: .codex), "codex")
    }

    // MARK: - adaptive layout

    func testAnalyticsRowsPairOnlyOnWideWindows() {
        XCTAssertTrue(analyticsUsesPairedRows(1900), "большой внешний экран — пары в строку")
        XCTAssertTrue(analyticsUsesPairedRows(CGFloat(1600)), "граница включена")
        XCTAssertFalse(analyticsUsesPairedRows(1400), "ноутбук — карточки друг под другом")
        XCTAssertFalse(analyticsUsesPairedRows(900))
    }
}
