import XCTest
import Foundation
@testable import CoveydCore

/// Недельная нормализация (§ скачки 7d-прогноза): ставка недели — EMA дельт
/// weekUsed с τ=24ч (всплеск 15 мин не должен двигать её заметно), полоса
/// p50/p90 из распределения 5-мин вёдер, дельты через разрывы не считаются.
final class WeeklyRateTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

    /// Серия 5-мин вёдер weekUsed с равномерным темпом cr/h.
    private func steady(hours: Double, rate: Double, endingAt end: Date) -> [QuotaSample] {
        var out: [QuotaSample] = []
        let steps = Int(hours * 12)
        let start = end.addingTimeInterval(-hours * 3600)
        for i in 0...steps {
            let t = start.addingTimeInterval(TimeInterval(i) * 300)
            out.append(QuotaSample(t: Int64(t.timeIntervalSince1970 * 1000),
                                   fiveUsed: 0, fiveReset: 0,
                                   weekUsed: rate / 12 * Double(i), weekReset: 0))
        }
        return out
    }

    func testSteadyWeeklyRateMatchesTrueRate() {
        let samples = steady(hours: 48, rate: 1000, endingAt: now)
        let r = ForecastEngine.weeklyRate(samples: samples, gaps: [],
                                          windowStart: now.addingTimeInterval(-48 * 3600),
                                          usedSoFar: 48_000, now: now)
        XCTAssertEqual(r.source, .daily)
        XCTAssertEqual(r.creditsPerHour, 1000, accuracy: 50, "48ч ровного темпа → EMA ≈ темп")
    }

    func testShortBurstDoesNotInflateWeeklyRate() {
        // 48ч по 1000 cr/h и всплеск 20000 cr/h на последние 15 минут.
        var samples = steady(hours: 48, rate: 1000, endingAt: now.addingTimeInterval(-900))
        let last = samples.last!.weekUsed
        samples.append(contentsOf: steady(hours: 0.25, rate: 20_000,
                                          endingAt: now).dropFirst()
            .map { s in QuotaSample(t: s.t, fiveUsed: 0, fiveReset: 0,
                                    weekUsed: last + s.weekUsed, weekReset: 0) })
        let r = ForecastEngine.weeklyRate(samples: samples, gaps: [],
                                          windowStart: now.addingTimeInterval(-48 * 3600),
                                          usedSoFar: last + 5000, now: now)
        XCTAssertLessThan(r.creditsPerHour, 1500,
                          "15-мин всплеск ×20 не должен поднимать суточную ставку в разы")
    }

    func testBurstIsNotIgnoredEither() {
        // Последние 6 часов темп 4000 на фоне 42 часов тишины — EMA должна
        // увидеть рост, но не скакнуть на 4000 (τ=24ч сглаживает).
        let samples = steady(hours: 48, rate: 0, endingAt: now.addingTimeInterval(-6 * 3600))
            + steady(hours: 6, rate: 4000, endingAt: now).dropFirst().map { s in
                QuotaSample(t: s.t, fiveUsed: 0, fiveReset: 0, weekUsed: 24_000 + s.weekUsed, weekReset: 0)
            }
        let r = ForecastEngine.weeklyRate(samples: samples, gaps: [],
                                          windowStart: now.addingTimeInterval(-48 * 3600),
                                          usedSoFar: 24_000, now: now)
        XCTAssertGreaterThan(r.creditsPerHour, 500, "рост виден")
        XCTAssertLessThan(r.creditsPerHour, 4000, "но без скачка до мгновенного темпа")
    }

    func testShortHistoryFallsBackToWindowAverage() {
        let samples = steady(hours: 1, rate: 1000, endingAt: now)
        let r = ForecastEngine.weeklyRate(samples: samples, gaps: [],
                                          windowStart: now.addingTimeInterval(-3600),
                                          usedSoFar: 1000, now: now)
        XCTAssertEqual(r.source, .windowAverage, "истории под EMA нет → среднее окна")
    }

    func testDeltasAcrossGapsAreSkipped() {
        // 24ч истории, в середине дыра 10 минут с «скачком» счётчика.
        var samples = steady(hours: 24, rate: 1000, endingAt: now.addingTimeInterval(-5 * 3600))
        let beforeGap = samples.last!
        let afterGapT = beforeGap.t + 10 * 60_000
        samples.append(QuotaSample(t: afterGapT, fiveUsed: 0, fiveReset: 0,
                                   weekUsed: beforeGap.weekUsed + 4000, weekReset: 0))
        samples.append(contentsOf: steady(hours: 5, rate: 1000, endingAt: now).dropFirst().map {
            QuotaSample(t: $0.t, fiveUsed: 0, fiveReset: 0,
                        weekUsed: beforeGap.weekUsed + 4000 + $0.weekUsed, weekReset: 0)
        })
        let gap = Double(beforeGap.t)..<Double(afterGapT)
        let r = ForecastEngine.weeklyRate(samples: samples, gaps: [gap],
                                          windowStart: now.addingTimeInterval(-29 * 3600),
                                          usedSoFar: samples.last!.weekUsed, now: now)
        XCTAssertLessThan(r.creditsPerHour, 1500, "дельта через разрыв не в счёт")
    }

    func testProjectedBandFromDeltaDistribution() {
        // 70% вёдер по 100, 30% по 300 cr/ч → p50 около 100, p90 около 300.
        var samples: [QuotaSample] = []
        var used = 0.0
        for i in 0..<120 {
            let rate = i % 10 < 7 ? 100.0 : 300.0
            used += rate / 12
            samples.append(QuotaSample(
                t: Int64(now.addingTimeInterval(TimeInterval(i - 119) * 300)
                    .timeIntervalSince1970 * 1000),
                fiveUsed: 0, fiveReset: 0, weekUsed: used, weekReset: 0))
        }
        let band = ForecastEngine.weeklyBand(samples: samples, gaps: [],
                                             resetAt: now.addingTimeInterval(48 * 3600),
                                             used: used, now: now)
        XCTAssertNotNil(band)
        XCTAssertEqual(band!.p50, used + 100 * 48, accuracy: 500)
        XCTAssertGreaterThan(band!.p90, band!.p50, "p90 выше p50")
    }
}
