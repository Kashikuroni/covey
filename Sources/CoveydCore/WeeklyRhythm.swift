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
