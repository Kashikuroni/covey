import XCTest
import Foundation
import CoveyKit
@testable import covey

/// Линейный график $-расходов (SpendCard): точки-интервалы по моделям
/// считаются из компонентов биллинга × прайс; day-режим берёт почасовки,
/// длинные — дневные вёдра; тотал — сумма периода.
final class SpendSeriesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cal = Calendar.current

    private let prices = ModelPrices(input: 1.0, cachedRead: 0.1, cacheWrite: 0, output: 10.0)
    private let flashPrices = ModelPrices(input: 0.1, cachedRead: 0.01, cacheWrite: 0, output: 0.5)

    private func cost(_ model: String, _ usage: GLMTokenUsage) -> Double? {
        switch model {
        case "glm-5.3": return SpendCardTestBridge.cost(usage, prices)
        case "glm-5.3-flash": return SpendCardTestBridge.cost(usage, flashPrices)
        default: return nil   // модель без прайса
        }
    }

    private func usage(_ input: Double, _ output: Double) -> GLMTokenUsage {
        GLMTokenUsage(input: input, output: output, cacheCreation: 0, cacheRead: 0)
    }

    func testDailySeriesFromModelDays() {
        var daily: [GLMDayUsage] = []
        for ago in 0..<7 {
            let day = cal.startOfDay(for: now.addingTimeInterval(TimeInterval(-ago) * 86_400))
            daily.append(GLMDayUsage(t: Int64(day.timeIntervalSince1970 * 1000),
                                     models: [:],
                                     usage: ["glm-5.3": usage(1_000_000, 100_000)]))
        }
        let s = SpendCard.series(hourly: [], daily: daily, range: .week,
                                 cost: cost, now: now)
        XCTAssertEqual(s.points.count, 7)
        // $ за день: 1M×1 + 0.1M×10 = $2.
        XCTAssertEqual(s.points.first?.byModel["glm-5.3"] ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(s.total ?? 0, 14.0, accuracy: 1e-9, "тотал за неделю")
    }

    func testDaySeriesFromHourly() {
        let h0 = Int64(now.timeIntervalSince1970 * 1000) / 3_600_000 * 3_600_000
        let hourly = (0..<24).map { off in
            GLMHourUsage(t: h0 - Int64(off) * 3_600_000,
                         usage: ["glm-5.3": usage(100_000, 10_000)])
        }
        let s = SpendCard.series(hourly: hourly, daily: [], range: .day,
                                 cost: cost, now: now)
        XCTAssertEqual(s.points.count, 24)
        // $ за час: 0.1M×1 + 0.01M×10 = $0.2; сутки = $4.8.
        XCTAssertEqual(s.total ?? 0, 4.8, accuracy: 1e-9)
    }

    func testModelsWithoutPriceAreSkippedButOthersCount() {
        let day = cal.startOfDay(for: now)
        let daily = [GLMDayUsage(t: Int64(day.timeIntervalSince1970 * 1000),
                                 models: [:],
                                 usage: ["glm-5.3": usage(1_000_000, 0),
                                         "unknown": usage(5_000_000, 0)])]
        let s = SpendCard.series(hourly: [], daily: daily, range: .week,
                                 cost: cost, now: now)
        XCTAssertNil(s.byModel["unknown"], "без прайса линии нет")
        XCTAssertEqual(s.total ?? 0, 1.0, accuracy: 1e-9)
    }

    func testCustomWindowFiltersPoints() {
        // Произвольный диапазон дат: точки берутся только внутри окна.
        var daily: [GLMDayUsage] = []
        for ago in 0..<10 {
            let day = cal.startOfDay(for: now.addingTimeInterval(TimeInterval(-ago) * 86_400))
            daily.append(GLMDayUsage(t: Int64(day.timeIntervalSince1970 * 1000),
                                     models: [:],
                                     usage: ["glm-5.3": usage(1_000_000, 0)]))
        }
        let from = cal.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let to = cal.startOfDay(for: now.addingTimeInterval(-2 * 86_400))
        let s = SpendCard.series(hourly: [], daily: daily,
                                 window: from...to.addingTimeInterval(86_400 - 1),
                                 cost: cost, now: now)
        XCTAssertEqual(s.points.count, 3, "дни 4,3,2 назад — окно [4д, 2д]")
        XCTAssertEqual(s.total ?? 0, 3.0, accuracy: 1e-9)
    }
}

/// Мост для тестов: тот же расчёт, что в реестре (цены фиксированы тестом).
enum SpendCardTestBridge {
    static func cost(_ usage: GLMTokenUsage, _ p: ModelPrices) -> Double {
        usage.input / 1_000_000 * p.input
            + usage.cacheRead / 1_000_000 * p.cachedRead
            + usage.cacheCreation / 1_000_000 * p.cacheWrite
            + usage.output / 1_000_000 * p.output
    }
}
