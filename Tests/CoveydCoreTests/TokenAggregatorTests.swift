import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

final class TokenAggregatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000)  // выровнен на минуту

    private func event(minutesAgo: Double, session: String = "s1", model: String = "glm-4.6",
                       sidechain: Bool = false, total: Double) -> TokenEvent {
        TokenEvent(t: t0 - minutesAgo * 60, sessionKey: session, model: model,
                   isSidechain: sidechain, input: total, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    func testSameMinuteEventsMergeIntoOneBucket() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 0, total: 10))
        agg.ingest(event(minutesAgo: -0.2, total: 15))  // 12 с ПОСЛЕ t0 — тот же минутный бакет
        XCTAssertEqual(agg.buckets.count, 1)
        XCTAssertEqual(agg.buckets.first?.total, 25)
    }

    func testActiveSessionRateIsLast15MinTimes4() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 5, total: 1000))
        agg.ingest(event(minutesAgo: 20, total: 999_999))  // за пределами 15-мин окна
        let rates = agg.sessionRates(now: t0, idle: 600)
        XCTAssertEqual(rates.count, 1)
        XCTAssertTrue(rates[0].active)
        XCTAssertEqual(rates[0].tokensPerHour, 4000, accuracy: 1)
    }

    func testIdleSessionIsInactiveButKeepsWindowTotal() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 30, total: 500))  // молчит 30 мин > idle 10 мин
        let rates = agg.sessionRates(now: t0, idle: 600)
        XCTAssertFalse(rates[0].active)
        XCTAssertEqual(rates[0].tokensPerHour, 0)
        XCTAssertEqual(rates[0].windowTotal, 500)
        XCTAssertEqual(agg.accountTokensPerHour(now: t0, idle: 600), 0)
    }

    func testTotalsSinceFiltersByTime() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 10, total: 100))
        agg.ingest(event(minutesAgo: 120, total: 900))
        XCTAssertEqual(agg.totals(since: t0 - 3600).total, 100, accuracy: 0.001)
        XCTAssertEqual(agg.totals(since: t0 - 7200).total, 1000, accuracy: 0.001)
    }

    func testPerModelSplitsWindowAndHour() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 5, model: "glm-4.6", total: 100))
        agg.ingest(event(minutesAgo: 30, model: "glm-4.5-air", total: 700))
        let models = agg.perModel(windowStart: t0 - 3600, hourStart: t0 - 3600)
        XCTAssertEqual(models.count, 2)
        let air = models.first { $0.model == "glm-4.5-air" }!
        XCTAssertEqual(air.window.total, 700, accuracy: 0.001)
        XCTAssertEqual(air.lastHour.total, 700, accuracy: 0.001)
    }

    func testRestoreFromBuckets() {
        let bucket = TokenBucket(m: Int64(t0.timeIntervalSince1970 * 1000) - 60_000, s: "s1",
                                 model: "glm-4.6", x: false, input: 100, output: 0,
                                 cacheCreation: 0, cacheRead: 0)
        let agg = TokenAggregator(buckets: [bucket])
        XCTAssertEqual(agg.totals(since: t0 - 3600).total, 100, accuracy: 0.001)
    }

    func testSessionTotalsCarryBillingComponents() {
        let agg = TokenAggregator()
        agg.ingest(TokenEvent(t: t0, sessionKey: "s", model: "glm-5.3", isSidechain: false,
                              input: 100, output: 10, cacheCreation: 5, cacheRead: 200))
        let totals = agg.sessionTotals()
        let usage = totals["s"]?.usage["glm-5.3"]
        XCTAssertEqual(usage?.input ?? 0 ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(usage?.output ?? 0 ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(usage?.cacheCreation ?? 0 ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(usage?.cacheRead ?? 0 ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(totals["s"]?.byModel["glm-5.3"] ?? 0, 315, accuracy: 0.001,
                       "total-словарь остаётся для совместимости")
    }

    func testPerDayGroupsTotalsByLocalDayAndModel() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 1, model: "glm-4.6", total: 100))
        agg.ingest(event(minutesAgo: 24 * 60, model: "glm-4.6", total: 200))
        agg.ingest(event(minutesAgo: 24 * 60, model: "claude-opus-4", total: 40))
        let days = agg.perDay(now: t0, days: 7)
        XCTAssertEqual(days.count, 2, "вчера и сегодня — два дневных ведра")
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.t, $0.models) })
        let byUsage = Dictionary(uniqueKeysWithValues: days.compactMap { d in
            d.usage.map { (d.t, $0) }
        })
        let total = days.reduce(0.0) { $0 + $1.models.values.reduce(0, +) }
        XCTAssertEqual(total, 340, accuracy: 0.001)
        let todayKey = Int64(Calendar.current.startOfDay(for: t0).timeIntervalSince1970 * 1000)
        XCTAssertEqual(byDay[todayKey]?["glm-4.6"] ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(byUsage[todayKey]?["glm-4.6"]?.input ?? 0, 100, accuracy: 0.001,
                       "дневное ведро несёт компоненты биллинга")
        let ydayKey = Int64(Calendar.current.startOfDay(
            for: t0.addingTimeInterval(-24 * 3600)).timeIntervalSince1970 * 1000)
        XCTAssertEqual(byDay[ydayKey]?["glm-4.6"] ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(byDay[ydayKey]?["claude-opus-4"] ?? 0, 40, accuracy: 0.001)
    }

    func testSessionTotalsSpanAndByModel() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 60, session: "a", model: "glm-4.6", total: 10))
        agg.ingest(event(minutesAgo: 30, session: "a", model: "glm-4.5-air", total: 5))
        agg.ingest(event(minutesAgo: 45, session: "b", model: "glm-4.6", total: 7))
        let totals = agg.sessionTotals()
        XCTAssertEqual(totals["a"]?.byModel["glm-4.6"], 10)
        XCTAssertEqual(totals["a"]?.byModel["glm-4.5-air"], 5)
        XCTAssertEqual(totals["b"]?.byModel["glm-4.6"], 7)
        XCTAssertLessThan(totals["a"]!.first, totals["a"]!.last, "первое раньше последнего")
    }

    func testSessionRatesExcludeNonGLMSessions() {
        // Сбор ведётся по всем моделям (клод/gpt остаются в вёдрах и журнале),
        // но темп GLM-прогноза — только GLM-сессии: claude-транскрипт в
        // rates не попадает.
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 1, session: "glm-s", model: "glm-5.3", total: 100))
        agg.ingest(event(minutesAgo: 1, session: "claude-s", model: "claude-opus-4-7", total: 500))
        let rates = agg.sessionRates(now: t0, idle: 600)
        XCTAssertEqual(rates.count, 1, "только GLM-сессия участвует в темпе")
        XCTAssertEqual(rates.first?.key, "glm-s")
        // Данные claude-модели в аналитике остались:
        XCTAssertEqual(agg.totals(since: .distantPast).total, 600, accuracy: 0.001)
    }

    func testHourTotalsGroupByHour() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 90, total: 10))   // прошлый час
        agg.ingest(event(minutesAgo: 30, total: 15))   // текущий час
        agg.ingest(event(minutesAgo: 5, total: 3))     // тот же текущий час — слито
        let hours = agg.hourTotals(now: t0)
        XCTAssertEqual(hours.count, 2, "разные часы — разные точки, один час слит")
        XCTAssertEqual(hours.map(\.used).reduce(0, +), 28, accuracy: 0.001)
    }

    func testPerHourGroupsByHourModelAndComponents() {
        let agg = TokenAggregator()
        agg.ingest(TokenEvent(t: t0, sessionKey: "s", model: "glm-5.3", isSidechain: false,
                              input: 100, output: 10, cacheCreation: 0, cacheRead: 50))
        agg.ingest(TokenEvent(t: t0, sessionKey: "s2", model: "glm-5.3-flash", isSidechain: false,
                              input: 30, output: 5, cacheCreation: 0, cacheRead: 0))
        let hours = agg.perHour(now: t0, days: 1)
        XCTAssertEqual(hours.count, 1, "один час — одна точка")
        let u = hours.first?.usage["glm-5.3"]
        XCTAssertEqual(u?.input ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(u?.output ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(u?.cacheRead ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(hours.first?.usage["glm-5.3-flash"]?.input ?? 0, 30, accuracy: 0.001)
    }

    func testEventsOlderThanEightDaysArePruned() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 9 * 24 * 60, total: 42))
        agg.ingest(event(minutesAgo: 1, total: 7))
        XCTAssertEqual(agg.totals(since: .distantPast).total, 7, accuracy: 0.001)
    }

    func testRemoveSessionLeavesOtherSessionsUntouched() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 1, session: "codex:s1", total: 42))
        agg.ingest(event(minutesAgo: 1, session: "codex:s2", total: 7))

        agg.removeSession("codex:s1")

        XCTAssertEqual(agg.buckets.map(\.s), ["codex:s2"])
        XCTAssertEqual(agg.totals(since: .distantPast).total, 7, accuracy: 0.001)
    }

    func testWallClockPruneDropsHistoricalLastIngestedEvent() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 9 * 24 * 60, total: 42))
        XCTAssertEqual(agg.buckets.count, 1,
                       "ingest only knows the historical event timestamp")

        agg.prune(now: t0)

        XCTAssertTrue(agg.buckets.isEmpty)
    }
}
