import XCTest
@testable import CoveydCore
import CoveyKit

/// ForecastAnalyticsBuilder: провайдер-нейтральная аналитика поверх общего
/// агрегатора — GPT-модели/сессии/составы видны без GLM, GLM-прогноз
/// не контаминируется GPT-токенами (спека «Построение provider-neutral
/// analytics»).
final class ForecastAnalyticsBuilderTests: XCTestCase {
    private let now = Date()
    private var store: QuotaSampleStore!

    override func setUpWithError() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".json"
        store = QuotaSampleStore(path: path)
    }

    private var homeApp: String { NSHomeDirectory() + "/work/app" }

    private func ingest(_ aggregator: TokenAggregator, key: String, model: String,
                        input: Double = 100, output: Double = 50) {
        aggregator.ingest(TokenEvent(t: now.addingTimeInterval(-60), sessionKey: key,
                                      model: model, isSidechain: false,
                                      input: input, output: output,
                                      cacheCreation: 0, cacheRead: 0))
    }

    // MARK: - session rates split

    func testAllSessionRatesIncludeEveryModelWhileGLMRatesFilter() {
        let agg = TokenAggregator()
        ingest(agg, key: "s-glm", model: "glm-5.3")
        ingest(agg, key: "s-gpt", model: "gpt-6-sol")
        let all = Set(agg.allSessionRates(now: now, idle: 600).map(\.key))
        let glm = Set(agg.glmSessionRates(now: now, idle: 600).map(\.key))
        XCTAssertEqual(all, ["s-glm", "s-gpt"], "аналитика видит все модели")
        XCTAssertEqual(glm, ["s-glm"], "GLM-прогноз — только GLM/z.ai")
    }

    // MARK: - builder

    func testBuilderPublishesGPTModelsSessionsAndCosts() throws {
        let agg = TokenAggregator()
        ingest(agg, key: "codex:s1", model: "gpt-6-sol")
        store.setSessionMetadata(ForecastSessionMetadata(source: .codex,
                                                         cwd: homeApp,
                                                         external: true),
                                 for: "codex:s1")
        store.upsertSessions(["codex:s1": SessionCostRecord(
            firstSeen: 1, lastSeen: 2, byModel: ["gpt-6-sol": 150],
            external: true, cwd: homeApp)], now: now)

        let analytics = ForecastAnalyticsBuilder.build(aggregator: agg, store: store,
                                                       identities: [], glmForecast: nil,
                                                       now: now)
        XCTAssertEqual(analytics.models.map(\.model), ["gpt-6-sol"])
        XCTAssertEqual(analytics.models.first?.window.input, 100)
        let session = try XCTUnwrap(analytics.sessions.first)
        XCTAssertEqual(session.id, "codex:s1")
        XCTAssertEqual(session.source, .codex)
        XCTAssertTrue(session.external)
        XCTAssertNil(session.creditsPerHour, "GPT-сессии не получают GLM-кредиты")
        XCTAssertNil(session.budgetMinutes)
        let cost = try XCTUnwrap(analytics.sessionCosts.first)
        XCTAssertEqual(cost.source, .codex)
        XCTAssertEqual(cost.name, "~/work/app", "внешнее имя — tilde-домашний cwd")
    }

    func testDuplicateExternalCwdsKeepDistinctStableIDs() {
        let agg = TokenAggregator()
        ingest(agg, key: "codex:a", model: "gpt-6-sol")
        ingest(agg, key: "codex:b", model: "gpt-6-sol")
        for key in ["codex:a", "codex:b"] {
            store.setSessionMetadata(ForecastSessionMetadata(source: .codex,
                                                             cwd: "/same/project",
                                                             external: true),
                                     for: key)
        }
        let analytics = ForecastAnalyticsBuilder.build(aggregator: agg, store: store,
                                                       identities: [], glmForecast: nil,
                                                       now: now)
        XCTAssertEqual(analytics.sessions.count, 2)
        XCTAssertEqual(Set(analytics.sessions.map(\.id)), ["codex:a", "codex:b"],
                       "одинаковый cwd не схлопывает сессии")
        // Имена внешних сессий с одинаковым cwd совпадают — различаются ID.
    }

    func testOnlyGLMSessionsReceiveCreditsAndBudget() throws {
        let agg = TokenAggregator()
        ingest(agg, key: "glm-live", model: "glm-5.3")
        ingest(agg, key: "codex:s1", model: "gpt-6-sol")

        var glmForecast = GLMForecast()
        glmForecast.agents = [GLMAgentForecast(
            name: "glm-live", id: "glm-live", external: false, active: true,
            isSidechainMarked: false, tokensPerHour: 1000,
            creditsPerHour: 42, sharePercent: 100, budgetMinutes: 77,
            cacheHit: nil, sidechainShare: nil, contextTokens: nil)]

        let analytics = ForecastAnalyticsBuilder.build(aggregator: agg, store: store,
                                                       identities: [],
                                                       glmForecast: glmForecast, now: now)
        let glmSession = try XCTUnwrap(analytics.sessions.first { $0.id == "glm-live" })
        XCTAssertEqual(glmSession.source, .claudeCode)
        XCTAssertEqual(glmSession.creditsPerHour, 42)
        XCTAssertEqual(glmSession.budgetMinutes, 77)
        let gptSession = try XCTUnwrap(analytics.sessions.first { $0.id == "codex:s1" })
        XCTAssertNil(gptSession.creditsPerHour)
        XCTAssertNil(gptSession.budgetMinutes)
    }

    func testCoveyIdentityNamesACodeXSessionsByRegistry() {
        let agg = TokenAggregator()
        ingest(agg, key: "codex:s1", model: "gpt-6-sol")
        store.setSessionMetadata(ForecastSessionMetadata(source: .codex,
                                                         cwd: homeApp,
                                                         external: false),
                                 for: "codex:s1")
        let identities = [ForecastSessionIdentity(sourceID: "codex:s1", name: "my-session",
                                                  cwd: homeApp, agent: "codex",
                                                  created: 1)]
        let analytics = ForecastAnalyticsBuilder.build(aggregator: agg, store: store,
                                                       identities: identities,
                                                       glmForecast: nil, now: now)
        XCTAssertEqual(analytics.sessions.first?.name, "my-session")
        XCTAssertEqual(analytics.sessions.first?.external, false)
    }

    func testExternalClaudeSessionResolvesProjectName() {
        // Спека: внешняя сессия — имя из реального cwd проекта (~), не ext:<uuid>.
        let agg = TokenAggregator()
        ingest(agg, key: "uuid-9", model: "glm-5.3")
        store.setOffset("/proj/my-slug/uuid-9.jsonl", 1)
        store.setCWD("my-slug", cwd: NSHomeDirectory() + "/work/x")
        let analytics = ForecastAnalyticsBuilder.build(aggregator: agg, store: store,
                                                       identities: [], glmForecast: nil,
                                                       now: now)
        XCTAssertEqual(analytics.sessions.first { $0.id == "uuid-9" }?.name, "~/work/x")
    }

    // MARK: - GLM non-contamination

    private func forecast(with aggregator: TokenAggregator) -> GLMForecast {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".json"
        let window = GLMLimitWindow(total: 1000, used: 100, remaining: 900,
                                    usedPercent: 10, remainingPercent: 90,
                                    resetAt: Int64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000))
        return ForecastEngine.build(fiveHours: window, weekly: nil,
                                    aggregator: aggregator,
                                    store: QuotaSampleStore(path: path),
                                    factors: CalibrationFactors(), now: now,
                                    config: GLMForecastConfig()).forecast
    }

    func testGPTUsageDoesNotChangeGLMForecastInputs() {
        let glmOnly = TokenAggregator()
        ingest(glmOnly, key: "glm-live", model: "glm-5.3")
        let mixed = TokenAggregator()
        ingest(mixed, key: "glm-live", model: "glm-5.3")
        ingest(mixed, key: "codex:s1", model: "gpt-6-sol", input: 10_000, output: 10_000)

        let a = forecast(with: glmOnly)
        let b = forecast(with: mixed)
        XCTAssertEqual(b.tokensPerHour, a.tokensPerHour,
                       "GPT-токены не меняют аккаунтный GLM-темп")
        XCTAssertEqual(b.agents.map(\.id), a.agents.map(\.id),
                       "GPT-сессии не попадают в GLM-агенты")
        XCTAssertEqual(b.models, a.models,
                       "GPT-модели не попадают в GLM-совместимые поля")
    }
}
