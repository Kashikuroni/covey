import XCTest
import CoveyKit

final class GLMForecastTests: XCTestCase {
    func testUsageSnapshotDecodesWithoutForecastField() throws {
        // Снапшот, записанный ДО появления glmForecast, обязан грузиться.
        let json = #"{"revision":7,"claudeUsageEnabled":true}"#
        let s = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.revision, 7)
        XCTAssertNil(s.glmForecast)
    }

    func testForecastRoundTrip() throws {
        var f = GLMForecast()
        f.tokensPerHour = 12_000
        f.fiveHours = GLMWindowForecast(verdict: .overflow, projected: 950, remaining: 800,
                                        total: 1000, resetAt: 2_000, exhaustionAt: 1_800,
                                        headroomPercent: -5, rateCreditsPerHour: 120, agentMinutes: 400)
        f.agents = [GLMAgentForecast(name: "fix-auth", external: false, active: true,
                                     isSidechainMarked: false, tokensPerHour: 12_000,
                                     creditsPerHour: 120, sharePercent: 100, budgetMinutes: 400)]
        f.fiveHourSeries = [GLMSeriesPoint(t: 1_000, used: 100), GLMSeriesPoint(t: 2_000, used: 220)]
        var snap = UsageSnapshot()
        snap.glmForecast = f
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(back.glmForecast, f)
    }

    func testTokenUsageTotal() {
        let u = GLMTokenUsage(input: 10, output: 5, cacheCreation: 3, cacheRead: 2)
        XCTAssertEqual(u.total, 20)
    }
}
