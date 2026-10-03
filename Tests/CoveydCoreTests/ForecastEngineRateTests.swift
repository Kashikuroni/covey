import XCTest
import Foundation
@testable import CoveydCore

final class ForecastEngineRateTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T11:00:00Z")!  // пт 11:00 UTC, офф-пик

    private func sample(minAgo: Int, fiveUsed: Double) -> QuotaSample {
        QuotaSample(t: Int64((t0 - TimeInterval(minAgo * 60)).timeIntervalSince1970 * 1000),
                    fiveUsed: fiveUsed, fiveReset: 0, weekUsed: 0, weekReset: 0)
    }

    private func rate(_ tokensPerHour: Double, active: Bool = true) -> (key: String, tokensPerHour: Double, active: Bool, windowTotal: Double, sidechainShare: Double) {
        ("s", tokensPerHour, active, 0, 0)
    }

    private func freshOffPeak() -> CalibrationFactors {
        var f = CalibrationFactors()
        f.offPeak = 0.05; f.offPeakAt = t0
        return f
    }

    func testInstantWinsWhenActiveSessionsAndFreshFactor() {
        let r = ForecastEngine.creditRate(samples: [], sessionRates: [rate(12_000)],
                                          factors: freshOffPeak(), now: t0,
                                          windowStart: t0 - 1800, usedSoFar: 100)
        XCTAssertEqual(r.source, .instant)
        XCTAssertEqual(r.creditsPerHour, 600, accuracy: 0.001)  // 12000 × 0.05
        XCTAssertEqual(r.tokensPerHour, 12_000, accuracy: 0.001)
    }

    func testInactiveSessionsFallThroughToWindowAverage() {
        let r = ForecastEngine.creditRate(samples: [], sessionRates: [rate(12_000, active: false)],
                                          factors: freshOffPeak(), now: t0,
                                          windowStart: t0 - 1800, usedSoFar: 100)
        XCTAssertEqual(r.source, .windowAverage)
        XCTAssertEqual(r.creditsPerHour, 200, accuracy: 0.001, "100 кр за 30 мин окна → 200/ч; дельт и активных сессий нет")
    }

    func testRecentFallsBackToMedianOfLast15MinDeltas() {
        // 15, 10, 5 мин назад: дельты 300, 300, 300 кредитов за 5 мин → 3600/ч.
        let r = ForecastEngine.creditRate(
            samples: [sample(minAgo: 15, fiveUsed: 0), sample(minAgo: 10, fiveUsed: 300),
                      sample(minAgo: 5, fiveUsed: 600), sample(minAgo: 0, fiveUsed: 900)],
            sessionRates: [], factors: freshOffPeak(), now: t0,
            windowStart: t0 - 1800, usedSoFar: 900)
        XCTAssertEqual(r.source, .recent)
        XCTAssertEqual(r.creditsPerHour, 3600, accuracy: 1)
    }

    func testWindowAverageIsLastResort() {
        let r = ForecastEngine.creditRate(samples: [], sessionRates: [], factors: CalibrationFactors(),
                                          now: t0, windowStart: t0 - 3600, usedSoFar: 720)
        XCTAssertEqual(r.source, .windowAverage)
        XCTAssertEqual(r.creditsPerHour, 720, accuracy: 1)
    }

    func testInstantFallsBackToRecentWhenFactorStale() {
        var stale = freshOffPeak()
        stale.offPeakAt = t0.addingTimeInterval(-30 * 24 * 3600)  // старше 7 дней
        let r = ForecastEngine.creditRate(
            samples: [sample(minAgo: 5, fiveUsed: 0), sample(minAgo: 0, fiveUsed: 300)],
            sessionRates: [rate(12_000)], factors: stale, now: t0,
            windowStart: t0 - 1800, usedSoFar: 300)
        XCTAssertEqual(r.source, .recent)
        XCTAssertEqual(r.creditsPerHour, 3600, accuracy: 1)
    }
}
