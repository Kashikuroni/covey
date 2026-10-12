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

    // MARK: - Симуляция горизонта (Task 3)

    private let rate = 100.0
    private let reset: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Almaty")!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
    }()

    private func simulate(rate: Double = 100.0, used: Double = 0, total: Double = 10_000,
                          five: (remaining: Double, total: Double, resetAt: Date)? = nil,
                          share: [Double]? = nil) -> WeeklyHorizon {
        WeeklyRhythm.projectHorizon(from: now, to: reset, rate: rate,
                                    share: share ?? [Double](repeating: 1, count: 168),
                                    calendar: cal, used: used, total: total, five: five)
    }

    func testNoGateMatchesRateTimesHours() {
        let hours = reset.timeIntervalSince(now) / 3600   // 168
        let h = simulate()
        XCTAssertEqual(h.burned, rate * hours, accuracy: 1)
        XCTAssertEqual(h.trajectory.first?.used, 0)
        XCTAssertEqual(h.trajectory.last?.t, Int64(reset.timeIntervalSince1970 * 1000))
    }

    func testShapeRedistributesBurn() {
        var share = [Double](repeating: 0, count: 168)
        share[(2 - 1) * 24 + 13] = 1   // весь расход во вторник 13:00
        let h = simulate(share: share)
        // Ровно один час из 168 сжигает всё: burned = rate × 1 (± часовой шаг).
        XCTAssertEqual(h.burned, rate, accuracy: 1.5)
    }

    func testPlateauWhenFiveHoursExhausted() {
        // Окно почти исчерпано: остатка хватает на полчаса ставок 100/ч.
        let fiveReset = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 18))!
        let h = simulate(five: (remaining: 50, total: 500, resetAt: fiveReset))
        let flats = zip(h.trajectory, h.trajectory.dropFirst())
            .filter { $0.used == $1.used && $0.t != $1.t }
        XCTAssertFalse(flats.isEmpty, "ожидается плато при исчерпанном 5h")
        XCTAssertLessThan(h.burned, 100 * 168, "ворота обязаны срезать расход")
    }

    func testLiveOverflowPlatesFromNow() {
        let fiveReset = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 17))!
        let h = simulate(five: (remaining: 0, total: 500, resetAt: fiveReset))
        XCTAssertEqual(h.trajectory[1].used, 0, "пока 5h исчерпан — линия плоская сразу")
    }

    func testStaleFiveResetRefillsImmediately() {
        let stale = now.addingTimeInterval(-3_600)
        let h = simulate(five: (remaining: 0, total: 500, resetAt: stale))
        XCTAssertGreaterThan(h.burned, 0, "протухший resetAt не запирает проекцию")
    }

    func testZeroRateYieldsFlatTrajectory() {
        let h = simulate(rate: 0)
        XCTAssertEqual(h.burned, 0)
        XCTAssertTrue(h.trajectory.allSatisfy { $0.used == 0 })
        XCTAssertNil(h.exhaustionAt)
    }

    func testExhaustionCrossesTotalAfterPlateau() {
        // total − used = 300: без ворот кончилось бы через 3 часа, с воротами позже.
        let fiveReset = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 18))!
        let gated = simulate(used: 0, total: 300,
                             five: (remaining: 100, total: 500, resetAt: fiveReset))
        let free = simulate(used: 0, total: 300)
        XCTAssertLessThan(free.exhaustionAt!, gated.exhaustionAt!)
    }
}
