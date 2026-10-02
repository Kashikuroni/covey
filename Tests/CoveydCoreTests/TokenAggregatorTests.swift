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

    func testEventsOlderThanEightDaysArePruned() {
        let agg = TokenAggregator()
        agg.ingest(event(minutesAgo: 9 * 24 * 60, total: 42))
        agg.ingest(event(minutesAgo: 1, total: 7))
        XCTAssertEqual(agg.totals(since: .distantPast).total, 7, accuracy: 0.001)
    }
}
