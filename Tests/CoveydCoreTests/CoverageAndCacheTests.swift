import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

/// Этап 1: cache hit (метрика попадания кэша) и покрытие мониторинга (доля
/// времени без разрывов опроса).
final class CoverageAndCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCacheHitFromTokenUsage() {
        var u = GLMTokenUsage(input: 100, output: 1, cacheCreation: 50, cacheRead: 850)
        XCTAssertEqual(u.cacheHit ?? 0, 0.85, accuracy: 0.001,
                       "hit = cacheRead / (cacheRead + input + cacheCreation)")
        u = GLMTokenUsage()
        XCTAssertNil(u.cacheHit, "без данных hit не определён")
    }

    func testSessionCacheHitFromRecentBuckets() {
        let agg = TokenAggregator()
        // Сессия s-hit: кэш читается, s-miss: всё с нуля. Rates видят только
        // GLM-сессии — модель glm.
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        agg.ingest(TokenEvent(t: t, sessionKey: "s-hit", model: "glm-5.3", isSidechain: false,
                              input: 100, output: 1, cacheCreation: 0, cacheRead: 900))
        agg.ingest(TokenEvent(t: t, sessionKey: "s-miss", model: "glm-5.3", isSidechain: false,
                              input: 1000, output: 1, cacheCreation: 0, cacheRead: 0))
        let rates = agg.glmSessionRates(now: t, idle: 600)
        let hit = rates.first { $0.key == "s-hit" }?.cacheHit
        let miss = rates.first { $0.key == "s-miss" }?.cacheHit
        XCTAssertNotNil(hit)
        if let hit { XCTAssertEqual(hit, 0.9, accuracy: 0.001) }
        if let miss { XCTAssertEqual(miss, 0, accuracy: 0.001) }
    }

    func testDataCoverageFromGaps() {
        // Окно 10 часов, разрыв на 1 час → покрытие 0.9.
        let start = now.addingTimeInterval(-10 * 3600)
        let gaps = [start.timeIntervalSince1970 * 1000 + 2 * 3_600_000
                    ..< start.timeIntervalSince1970 * 1000 + 3 * 3_600_000]
        let covered = ForecastEngine.dataCoverage(gaps: gaps, windowStart: start, now: now)
        let full = ForecastEngine.dataCoverage(gaps: [], windowStart: start, now: now)
        if let covered { XCTAssertEqual(covered, 0.9, accuracy: 0.001) } else { XCTFail() }
        if let full { XCTAssertEqual(full, 1.0, accuracy: 0.001) } else { XCTFail() }
    }
}
