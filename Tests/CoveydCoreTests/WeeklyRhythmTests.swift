import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

final class WeeklyRhythmTests: XCTestCase {
    /// Фиксированная зона и «сейчас»: пн 12 окт 2026, 12:00.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Almaty")!
        return c
    }
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    }

    /// Сутки целиком: рабочие часы пн–пт жгут `tokens`, остальное — нули
    /// (после релиза это живые метки простоя).
    private func totals(daysBack: Int, workTokens: Double,
                        workdays: ClosedRange<Int> = 2...6,
                        workHours: ClosedRange<Int> = 9...19) -> [GLMSeriesPoint] {
        var out: [GLMSeriesPoint] = []
        for d in 0..<daysBack {
            guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let wd = cal.component(.weekday, from: day)
            for h in 0..<24 {
                guard let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: day) else { continue }
                let used = (workdays.contains(wd) && workHours.contains(h)) ? workTokens : 0
                out.append(GLMSeriesPoint(t: Int64(t.timeIntervalSince1970 * 1000), used: used))
            }
        }
        return out
    }

    private func slot(_ weekday: Int, _ hour: Int) -> Int { (weekday - 1) * 24 + hour }

    func testWorkdayShapeNightNearZeroAndSumNormalized() {
        let r = WeeklyRhythm(hourTotals: totals(daysBack: 28, workTokens: 100),
                             now: now, calendar: cal)
        XCTAssertTrue(r.valid)
        XCTAssertLessThan(r.share[slot(3, 3)], 0.1)      // ночь среды ≈ 0
        XCTAssertGreaterThan(r.share[slot(3, 14)], 1.2)  // день среды заметно выше среднего
        XCTAssertEqual(r.share.reduce(0, +), 168, accuracy: 1)
    }

    func testFlatHistoryYieldsUnitShares() {
        // Равномерные записи без нулей: guard legacy-истории такие данные
        // объявляет невалидными (нет живых меток простоя), но нормировка
        // обязана дать единичные доли — проверяем именно её.
        let r = WeeklyRhythm(hourTotals: totals(daysBack: 14, workTokens: 50,
                                                workdays: 1...7, workHours: 0...23),
                             now: now, calendar: cal)
        for s in r.share { XCTAssertEqual(s, 1, accuracy: 0.001) }
    }

    func testInvalidWithThirteenDays() {
        XCTAssertFalse(WeeklyRhythm(hourTotals: totals(daysBack: 13, workTokens: 100),
                                    now: now, calendar: cal).valid)
    }

    func testLegacyHistoryWithoutZerosIsInvalid() {
        // До релиза живых меток: только активные часы. Ритм не должен включиться.
        var legacy = totals(daysBack: 28, workTokens: 100)
        legacy = legacy.filter { $0.used > 0 }
        XCTAssertFalse(WeeklyRhythm(hourTotals: legacy, now: now, calendar: cal).valid)
    }

    func testFactorWeightingLiftsPeakHourShare() {
        let factor: (Date) -> Double = { [cal] d in cal.component(.hour, from: d) == 15 ? 2 : 1 }
        let r = WeeklyRhythm(hourTotals: totals(daysBack: 14, workTokens: 50,
                                                workdays: 1...7, workHours: 0...23),
                             now: now, calendar: cal, factor: factor)
        // Свёртка [0.25,0.5,0.25] размазывает одиночный пик: центр ~1.5 против
        // ~1.0 вдали от него — проверяем усиление в этих границах.
        let ratio = r.share[slot(4, 15)] / max(1e-9, r.share[slot(4, 10)])
        XCTAssertGreaterThan(ratio, 1.3)
        XCTAssertLessThan(ratio, 1.8)
    }
}
