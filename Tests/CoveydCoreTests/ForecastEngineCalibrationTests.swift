import XCTest
import Foundation
@testable import CoveydCore

final class ForecastEngineCalibrationTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T11:00:00Z")!  // пт 11:00 UTC, офф-пик


    private func sample(minAgo: Int, fiveUsed: Double) -> QuotaSample {
        QuotaSample(t: Int64((t0 - TimeInterval(minAgo * 60)).timeIntervalSince1970 * 1000),
                    fiveUsed: fiveUsed, fiveReset: 0, weekUsed: 0, weekReset: 0)
    }

    private func bucket(minAgo: Int, total: Double, model: String = "glm-4.6") -> TokenBucket {
        let m = Int64((t0 - TimeInterval(minAgo * 60)).timeIntervalSince1970 * 1000)
        return TokenBucket(m: m - m % 60_000, s: "s1", model: model, x: false,
                           input: total, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    func testOffPeakFactorIsDeltaCreditsOverDeltaTokens() {
        // За 5 минут: +500 кредитов, 10_000 токенов → фактор 0.05.
        let f = ForecastEngine.calibrate(
            previous: CalibrationFactors(),
            samples: [sample(minAgo: 5, fiveUsed: 1000), sample(minAgo: 0, fiveUsed: 1500)],
            buckets: [bucket(minAgo: 4, total: 4000), bucket(minAgo: 2, total: 6000)],
            now: t0)
        XCTAssertNil(f.peak, "интервал целиком офф-пик — пик не трогаем")
        XCTAssertEqual(f.offPeak ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(f.recentOffPeak, [0.05])
    }

    func testPeakAndOffPeakCalibrateSeparatelyAcrossRegimeBoundary() {
        // t0 = пт 11:00 UTC (офф-пик); 10:00 UTC — граница: интервал 09:55→10:05 UTC
        // пересекает пик? Нет: до 06:00 UTC было пятно… берём заведомо пиковый интервал:
        // пт 07:00→07:05 UTC (пик, 15:00 UTC+8). minutesAgo от t0: 240→245.
        let samples = [sample(minAgo: 245, fiveUsed: 1000), sample(minAgo: 240, fiveUsed: 1500)]
        let buckets = [bucket(minAgo: 244, total: 5000), bucket(minAgo: 241, total: 5000)]
        let f = ForecastEngine.calibrate(previous: CalibrationFactors(), samples: samples,
                                         buckets: buckets, now: t0)
        XCTAssertNil(f.offPeak)
        XCTAssertEqual(f.peak ?? 0, 0.05, accuracy: 0.0001)
    }

    func testMedianSmoothsOutlier() {
        var prev = CalibrationFactors()
        prev.recentOffPeak = [0.05, 0.05, 0.05]
        // Новый валидный интервал с завышенным фактором 0.5 — медиана 4 значений гасит.
        let f = ForecastEngine.calibrate(previous: prev,
                                         samples: [sample(minAgo: 2, fiveUsed: 0),
                                                   sample(minAgo: 0, fiveUsed: 500)],
                                         buckets: [bucket(minAgo: 1, total: 1000)], now: t0)
        XCTAssertEqual(f.offPeak ?? 0, 0.05, accuracy: 0.0001)
    }

    func testStaleIntervalIsIgnored() {
        // Дельта за 2 часа — не минутная серия свежее 30 мин: фактор не строится.
        let f = ForecastEngine.calibrate(previous: CalibrationFactors(),
                                         samples: [sample(minAgo: 120, fiveUsed: 0),
                                                   sample(minAgo: 0, fiveUsed: 9999)],
                                         buckets: [bucket(minAgo: 60, total: 1000)], now: t0)
        XCTAssertNil(f.offPeak)
    }

    func testFreshnessWindowIsSevenDays() {
        var f = CalibrationFactors()
        f.offPeak = 0.05; f.offPeakAt = t0.addingTimeInterval(-8 * 24 * 3600)
        XCTAssertFalse(ForecastEngine.isFresh(f, peak: false, now: t0))
        f.offPeakAt = t0.addingTimeInterval(-6 * 24 * 3600)
        XCTAssertTrue(ForecastEngine.isFresh(f, peak: false, now: t0))
    }

    func testZeroTokenIntervalIsSkipped() {
        let f = ForecastEngine.calibrate(previous: CalibrationFactors(),
                                         samples: [sample(minAgo: 2, fiveUsed: 100),
                                                   sample(minAgo: 0, fiveUsed: 600)],
                                         buckets: [], now: t0)
        XCTAssertNil(f.offPeak, "кредиты потекли, а токен-вёдер нет (сетевой скачок/чужой клиент) — интервал невалиден")
    }
}
