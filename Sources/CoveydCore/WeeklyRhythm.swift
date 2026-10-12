import Foundation
import CoveyKit

/// Профиль недельного ритма расхода: доля часа недели относительно среднего
/// наблюдаемого часа (спека §3). Уровень темпа даёт EMA-ставка; профиль
/// задаёт только форму. Выводится из store.hourTotals, не персистится.
public struct WeeklyRhythm: Equatable, Sendable {
    public static let slotsPerWeek = 168
    static let windowDays = 28.0
    static let minObservedDays = 14
    static let minObservedSlots = 84
    /// Минимальная доля веса нулевых записей: защита от включения на legacy-
    /// истории, где записаны только активные часы (спека §8, warmup-перекос).
    static let minZeroWeightShare = 0.02

    public var share: [Double]          // 168 значений, средний слот = 1
    public var observedDays: Int
    public var observedSlots: Int
    public var sampledAt: Date
    var zeroWeightShare: Double

    public var valid: Bool {
        observedDays >= Self.minObservedDays
            && observedSlots >= Self.minObservedSlots
            && zeroWeightShare >= Self.minZeroWeightShare
    }

    /// Час недели: (вс=1 … сб=7) → (weekday−1)·24 + hour, локальный календарь.
    public static func slot(of date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        return ((c.weekday! - 1) * 24 + c.hour!) % Self.slotsPerWeek
    }

    public init(hourTotals: [GLMSeriesPoint], now: Date,
                calendar: Calendar = .current, factor: ((Date) -> Double)? = nil) {
        let windowStart = now.addingTimeInterval(-Self.windowDays * 86_400)
        var m = [Double](repeating: 0, count: Self.slotsPerWeek)
        var w = [Double](repeating: 0, count: Self.slotsPerWeek)
        var count = [Int](repeating: 0, count: Self.slotsPerWeek)
        var totalW = 0.0, totalWX = 0.0, zeroW = 0.0
        var days = Set<Int64>()
        for p in hourTotals {
            let t = Date(timeIntervalSince1970: Double(p.t) / 1000)
            guard t >= windowStart, t <= now else { continue }
            let weight = max(0, 1 - now.timeIntervalSince(t) / 86_400 / Self.windowDays)
            let mid = t.addingTimeInterval(1800)
            let tokens = p.used * (factor?(mid) ?? 1)
            let s = Self.slot(of: t, calendar: calendar)
            m[s] += weight * tokens
            w[s] += weight
            count[s] += 1
            totalW += weight
            totalWX += weight * tokens
            if p.used == 0 { zeroW += weight }
            days.insert(Int64(calendar.startOfDay(for: t).timeIntervalSince1970))
        }
        observedDays = days.count
        observedSlots = (0..<Self.slotsPerWeek).filter { count[$0] > 0 }.count
        zeroWeightShare = totalW > 0 ? zeroW / totalW : 0

        var result = [Double](repeating: 1, count: Self.slotsPerWeek)
        let g = totalW > 0 ? totalWX / totalW : 0
        if g > 0, totalW > 0 {
            // Слот наблюдаем при ≥2 записях (спека §3.3: счёт, не веса).
            for s in 0..<Self.slotsPerWeek where count[s] >= 2 {
                result[s] = (m[s] / w[s]) / g
            }
            // Ненаблюдаемые слоты наследуют круговых соседей ±1ч / ±1 день.
            for s in 0..<Self.slotsPerWeek where count[s] == 0 {
                var inherited: [Double] = []
                for off in [1, -1, 24, -24] {
                    let n = (s + off + Self.slotsPerWeek) % Self.slotsPerWeek
                    if w[n] > 0 { inherited.append(result[n]) }
                }
                if !inherited.isEmpty {
                    result[s] = inherited.reduce(0, +) / Double(inherited.count)
                }
            }
        }
        // Сглаживание круговой свёрткой [0.25, 0.5, 0.25].
        var smoothed = [Double](repeating: 0, count: Self.slotsPerWeek)
        for s in 0..<Self.slotsPerWeek {
            smoothed[s] = 0.25 * result[(s + Self.slotsPerWeek - 1) % Self.slotsPerWeek]
                + 0.5 * result[s]
                + 0.25 * result[(s + 1) % Self.slotsPerWeek]
        }
        // Нормировка: средний слот = 1.
        let sum = smoothed.reduce(0, +)
        share = sum > 0 ? smoothed.map { $0 * Double(Self.slotsPerWeek) / sum } : smoothed
        sampledAt = now
    }
}

/// Результат симуляции остатка недели: сжигание, траектория для карточки,
/// момент исчерпания (спека §4).
public struct WeeklyHorizon: Equatable, Sendable {
    public var burned: Double
    public var trajectory: [GLMSeriesPoint]
    public var exhaustionAt: Int64?
}

extension WeeklyRhythm {
    /// Почасовая симуляция (now, resetAt]: inc(h) = rate·share[h]; при
    /// исчерпанном 5h-остатке — плато до ближайшего сброса, затем окно
    /// заполняется `five.total` (окна идут подряд — приближение спеки §4).
    /// Часовое разрешение: плато внутри часа округляется (спека §8, <1ч).
    public static func projectHorizon(from now: Date, to resetAt: Date,
                                      rate: Double, share: [Double],
                                      calendar: Calendar,
                                      used: Double, total: Double,
                                      five: (remaining: Double, total: Double, resetAt: Date)?) -> WeeklyHorizon {
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        var burned = 0.0
        var points: [GLMSeriesPoint] = [GLMSeriesPoint(t: ms(now), used: used)]
        var exhaustion: Int64?
        func emit(_ at: Date) {
            points.append(GLMSeriesPoint(t: ms(at), used: used + burned))
            if exhaustion == nil, used + burned >= total { exhaustion = ms(at) }
        }
        var fiveRemain = five?.remaining ?? .infinity
        let fiveTotal = five?.total ?? .infinity
        var fiveReset = five?.resetAt ?? .distantFuture
        let end = resetAt
        guard rate >= 0, share.count == slotsPerWeek, end > now else {
            return WeeklyHorizon(burned: 0, trajectory: points, exhaustionAt: nil)
        }

        var hour = calendar.dateInterval(of: .hour, for: now)!.start
        if hour < now { hour = hour.addingTimeInterval(3600) }
        while hour < end {
            if fiveRemain <= 0 {
                if fiveReset > hour {
                    emit(min(fiveReset, end))             // плато
                    if fiveReset >= end { break }
                    hour = fiveReset                      // пауза съела часть горизонта
                }
                fiveRemain = fiveTotal                    // протухший reset — сразу refill
                fiveReset = fiveReset.addingTimeInterval(5 * 3600)
            }
            let slot = Self.slot(of: hour, calendar: calendar)
            let stepEnd = min(hour.addingTimeInterval(3600), end)
            let frac = stepEnd.timeIntervalSince(max(hour, now)) / 3600
            var inc = rate * share[slot] * max(0, frac)
            if inc > fiveRemain { inc = max(0, fiveRemain) }
            fiveRemain -= inc
            burned += inc
            emit(stepEnd)
            hour = hour.addingTimeInterval(3600)
        }
        if exhaustion == nil, used + burned >= total, let last = points.last {
            exhaustion = last.t
        }
        return WeeklyHorizon(burned: burned, trajectory: points, exhaustionAt: exhaustion)
    }
}
