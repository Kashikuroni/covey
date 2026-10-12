import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

final class WeeklyRhythmIntegrationTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Almaty")!
        return c
    }
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    }

    private func window(total: Double, used: Double, remaining: Double,
                        reset: Date) -> GLMLimitWindow {
        GLMLimitWindow(total: total, used: used, remaining: remaining,
                       usedPercent: used / total * 100,
                       remainingPercent: remaining / total * 100,
                       resetAt: Int64(reset.timeIntervalSince1970 * 1000))
    }

    /// 14 дней круглосуточной истории с нулевыми часами → профиль валиден.
    private func storeWithHistory() -> QuotaSampleStore {
        let store = QuotaSampleStore(path: nil)
        var points: [GLMSeriesPoint] = []
        for d in 0..<14 {
            let day = cal.date(byAdding: .day, value: -d, to: now)!
            for h in 0..<24 {
                let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: day)!
                points.append(GLMSeriesPoint(t: Int64(t.timeIntervalSince1970 * 1000),
                                             used: h == 3 ? 0 : 10))
            }
        }
        store.upsertHourTotals(points, now: now)
        store.markAliveHours(points.map(\.t), now: now)
        return store
    }

    /// Ставка из дельт weekUsed: 600/ч, шаг 1 минута, 8 часов = 481 сэмпл.
    /// Продуктовый инвариант стора: пауза опроса >3 мин метится gap'ом и
    /// выбрасывает интервалы из EMA — тестовый опрос обязан быть поминутным.
    private func storeWithSamples(_ store: QuotaSampleStore) {
        for m in stride(from: 480, through: 0, by: -1) {
            let t = now.addingTimeInterval(Double(-m) * 60)
            store.append(QuotaSample(t: Int64(t.timeIntervalSince1970 * 1000),
                                     fiveUsed: 100, fiveReset: 0,
                                     weekUsed: 600 * Double(480 - m) / 60, weekReset: 0))
        }
    }

    private var weekWindow: GLMLimitWindow {
        window(total: 5_000, used: 300, remaining: 4_700,
               reset: cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!)
    }

    func testBuildWeeklyProducesTrajectory() throws {
        let store = storeWithHistory()
        storeWithSamples(store)
        let (forecast, _) = ForecastEngine.build(
            fiveHours: window(total: 1_000_000, used: 0, remaining: 1_000_000,
                              reset: now.addingTimeInterval(2 * 3600)),
            weekly: weekWindow, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now,
            config: GLMForecastConfig())
        let weekly = try XCTUnwrap(forecast.weekly)
        let path = try XCTUnwrap(weekly.projectedPath)
        XCTAssertGreaterThanOrEqual(path.count, 2)
        XCTAssertNotNil(forecast.weeklyRhythm)
        XCTAssertEqual(weekly.projected, 300 + 600 * 72, accuracy: 1200,
                       "равномерная история → плоский эквивалент rate·72ч (reset +3д)")
        // Полоса из тех же дельт (все дельты 600/ч → p50 = p90 = ставка):
        // p50 ≤ projected ≤ p90 с допуском на часовой шаг (спека §7.6).
        let p50 = try XCTUnwrap(weekly.projectedP50)
        let p90 = try XCTUnwrap(weekly.projectedP90)
        XCTAssertLessThanOrEqual(p50, weekly.projected + 600)
        XCTAssertLessThanOrEqual(weekly.projected, p90 + 600)
    }

    func testInvalidRhythmKeepsFlatBehavior() {
        let store = QuotaSampleStore(path: nil)   // истории нет
        storeWithSamples(store)
        let (forecast, _) = ForecastEngine.build(
            fiveHours: nil, weekly: weekWindow, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now,
            config: GLMForecastConfig())
        XCTAssertNil(forecast.weekly?.projectedPath)
        XCTAssertNil(forecast.weeklyRhythm)
        // Полоса живёт и без ритма (спека §4: fallback = плоское поведение,
        // включая weeklyBand при ≥24 дельтах).
        XCTAssertNotNil(forecast.weekly?.projectedP50, "полоса не должна исчезать при невалидном ритме")
        XCTAssertNotNil(forecast.weekly?.projectedP90)
    }

    func testConfigFlagDisablesRhythm() {
        let store = storeWithHistory()
        storeWithSamples(store)
        var config = GLMForecastConfig()
        config.useWeeklyRhythm = false
        let (forecast, _) = ForecastEngine.build(
            fiveHours: nil, weekly: weekWindow, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now, config: config)
        XCTAssertNil(forecast.weekly?.projectedPath)
    }

    func testGateCapsProjected() {
        let store = storeWithHistory()
        storeWithSamples(store)
        // 5h: остаток 50 — почти сразу плато; projected должен упасть против свободного.
        let gated = ForecastEngine.build(
            fiveHours: window(total: 500, used: 450, remaining: 50,
                              reset: now.addingTimeInterval(3600)),
            weekly: weekWindow, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now,
            config: GLMForecastConfig()).forecast.weekly!.projected
        let free = ForecastEngine.build(
            fiveHours: window(total: 500, used: 0, remaining: 500,
                              reset: now.addingTimeInterval(3600)),
            weekly: weekWindow, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now,
            config: GLMForecastConfig()).forecast.weekly!.projected
        XCTAssertLessThan(gated, free)
    }

    /// Траектория не пересекает total → ETA нет: плоский exhaustionAt
    /// (ставится при любом effectiveRate > 0) не должен утекать в ритм-ветку,
    /// иначе UI рисует «exhausts» вопреки линии и вердикту (спека §4).
    func testGatedTrajectoryWithoutCrossingHasNoExhaustion() {
        let store = storeWithHistory()
        storeWithSamples(store)
        let big = window(total: 500_000, used: 300, remaining: 499_700,
                         reset: cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!)
        let (forecast, _) = ForecastEngine.build(
            fiveHours: window(total: 1_000_000, used: 0, remaining: 1_000_000,
                              reset: now.addingTimeInterval(2 * 3600)),
            weekly: big, aggregator: TokenAggregator(buckets: []),
            store: store, factors: CalibrationFactors(), now: now,
            config: GLMForecastConfig())
        XCTAssertNotNil(forecast.weekly?.projectedPath)
        XCTAssertNil(forecast.weekly?.exhaustionAt)
    }

    func testDecodesOldSnapshot() throws {
        // Синтезированный Codable требует все не-опциональные ключи, даже с
        // дефолтами: старый снапшот содержит их, но не содержит новых полей.
        let json = #"{"tokensPerHour":0,"peakNow":false,"agents":[],"models":[],"fiveHourSeries":[],"weeklySeries":[],"updatedAt":1}"#
        let f = try JSONDecoder().decode(GLMForecast.self, from: Data(json.utf8))
        XCTAssertNil(f.weeklyRhythm)
        let old = #"{"verdict":"fits","projected":1,"remaining":2,"total":3,"headroomPercent":1,"rateCreditsPerHour":0}"#
        let w = try JSONDecoder().decode(GLMWindowForecast.self, from: Data(old.utf8))
        XCTAssertNil(w.projectedPath)
    }
}
