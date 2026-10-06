import XCTest
import Foundation
import CoveyKit
@testable import covey

/// Диапазоны столбчатого графика: неделя/месяц — дневные столбцы,
/// квартал — недельные, год — месячные вёдра; подпись — «дней назад» от
/// начала столбца, свежий столбец — «today».
final class ModelBinsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cal = Calendar.current

    private func dayKey(_ date: Date) -> Int64 {
        Int64(cal.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }

    private func daily(daysAgo: Int, model: String, tokens: Double) -> GLMDayUsage {
        GLMDayUsage(t: dayKey(now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)),
                    models: [model: tokens])
    }

    private func label(_ date: Date) -> String {
        ModelBarsCard.barLabel.string(from: cal.startOfDay(for: date))
    }

    func testWeekBinsStayDaily() {
        let bins = ModelBarsCard.bins(from: [daily(daysAgo: 0, model: "m", tokens: 10),
                                             daily(daysAgo: 6, model: "m", tokens: 20)],
                                      range: .week, now: now)
        XCTAssertEqual(bins.count, 7)
        XCTAssertEqual(bins.first?.label, label(now.addingTimeInterval(-6 * 86_400)),
                       "таймлайн слева направо: старые слева, подпись — дата")
        XCTAssertEqual(bins.first?.models["m"], 20)
        XCTAssertEqual(bins.last?.label, label(now))
        XCTAssertEqual(bins.last?.models["m"], 10)
        XCTAssertTrue(bins.allSatisfy { $0.label.range(of: #"^\w{3} \d{2}\.\d{2}$"#,
                                                        options: .regularExpression) != nil },
                      "формат «Tue 10.06»")
    }

    func testQuarterAggregatesWeekly() {
        var input: [GLMDayUsage] = []
        for ago in 0...20 { input.append(daily(daysAgo: ago, model: "m", tokens: 5)) }
        let bins = ModelBarsCard.bins(from: input, range: .quarter, now: now)
        XCTAssertLessThanOrEqual(bins.count, 14, "квартал — недельные столбцы")
        let total = bins.reduce(0.0) { $0 + $1.models.values.reduce(0, +) }
        XCTAssertEqual(total, 105, accuracy: 0.001, "токены не теряются при агрегации")
        XCTAssertEqual(bins.last?.label, label(now))
    }

    func testYearAggregatesMonthly() {
        var input: [GLMDayUsage] = []
        for ago in 0...100 { input.append(daily(daysAgo: ago, model: "m", tokens: 3)) }
        let bins = ModelBarsCard.bins(from: input, range: .year, now: now)
        XCTAssertLessThanOrEqual(bins.count, 13, "год — месячные столбцы")
        let total = bins.reduce(0.0) { $0 + $1.models.values.reduce(0, +) }
        XCTAssertEqual(total, 303, accuracy: 0.001)
    }

    func testRangeDaysAndTitles() {
        XCTAssertEqual(ModelBarsCard.Range.week.days, 7)
        XCTAssertEqual(ModelBarsCard.Range.month.days, 30)
        XCTAssertEqual(ModelBarsCard.Range.quarter.days, 91)
        XCTAssertEqual(ModelBarsCard.Range.year.days, 365)
    }
}
