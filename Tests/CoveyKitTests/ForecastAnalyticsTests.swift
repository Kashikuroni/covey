import XCTest
import CoveyKit

final class ForecastAnalyticsTests: XCTestCase {
    func testForecastAnalyticsRoundTripsThroughUsageSnapshot() throws {
        var snapshot = UsageSnapshot()
        snapshot.forecastAnalytics = ForecastAnalytics(
            models: [
                GLMModelUsage(
                    model: "gpt-6-sol",
                    window: GLMTokenUsage(input: 10),
                    lastHour: GLMTokenUsage(input: 10))
            ],
            modelDaily: [],
            hourly: [],
            modelHourly: [],
            sessions: [
                ForecastSessionUsage(
                    id: "codex:s1",
                    name: "app",
                    source: .codex,
                    external: true,
                    active: true,
                    tokensPerHour: 1_200,
                    cacheHit: 0.5,
                    contextTokens: 8_000,
                    contextDeltaPerTurn: 500,
                    creditsPerHour: nil,
                    budgetMinutes: nil)
            ],
            sessionCosts: [])

        let decoded = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded.forecastAnalytics, snapshot.forecastAnalytics)
    }

    func testOldSnapshotBuildsLegacyAnalyticsFallback() throws {
        var legacyForecast = GLMForecast()
        legacyForecast.models = [
            GLMModelUsage(
                model: "glm-5.3",
                window: GLMTokenUsage(input: 20),
                lastHour: GLMTokenUsage(input: 5))
        ]
        legacyForecast.modelDaily = [
            GLMDayUsage(t: 1_000, models: ["glm-5.3": 20])
        ]
        legacyForecast.hourly = [GLMSeriesPoint(t: 1_000, used: 20)]
        legacyForecast.modelHourly = [
            GLMHourUsage(t: 1_000, usage: ["glm-5.3": GLMTokenUsage(input: 20)])
        ]
        legacyForecast.sessionCosts = [
            GLMSessionCostEntry(
                record: SessionCostRecord(
                    firstSeen: 1,
                    lastSeen: 2,
                    byModel: ["glm-5.3": 20],
                    external: false,
                    cwd: "/work/app"),
                name: "app",
                live: true)
        ]
        var legacySnapshot = UsageSnapshot()
        legacySnapshot.glmForecast = legacyForecast

        let decoded = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONEncoder().encode(legacySnapshot))

        XCTAssertEqual(decoded.forecastAnalytics?.models.first?.model, "glm-5.3")
        XCTAssertEqual(decoded.forecastAnalytics?.modelDaily.count, 1)
        XCTAssertEqual(decoded.forecastAnalytics?.hourly.count, 1)
        XCTAssertEqual(decoded.forecastAnalytics?.modelHourly.count, 1)
        XCTAssertEqual(decoded.forecastAnalytics?.sessionCosts.first?.source, .claudeCode)
    }

    func testQuotaOnlyLegacyForecastDoesNotCreateAnalytics() throws {
        var forecast = GLMForecast()
        forecast.fiveHours = GLMWindowForecast(
            verdict: .fits,
            projected: 10,
            remaining: 90,
            total: 100,
            resetAt: 2_000,
            exhaustionAt: nil,
            headroomPercent: 90,
            rateCreditsPerHour: 1,
            agentMinutes: nil)
        var snapshot = UsageSnapshot()
        snapshot.glmForecast = forecast

        let decoded = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONEncoder().encode(snapshot))

        XCTAssertNil(decoded.forecastAnalytics)
    }
}
