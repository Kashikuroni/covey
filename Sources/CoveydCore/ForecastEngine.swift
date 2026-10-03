import Foundation
import CoveyKit

/// Калиброванные факторы «кредиты за токен», раздельно по режимам.
struct CalibrationFactors: Equatable {
    var peak: Double?
    var offPeak: Double?
    var peakAt: Date?
    var offPeakAt: Date?
    var recentPeak: [Double] = []
    var recentOffPeak: [Double] = []

    init(peak: Double? = nil, offPeak: Double? = nil, peakAt: Date? = nil,
         offPeakAt: Date? = nil, recentPeak: [Double] = [], recentOffPeak: [Double] = []) {
        self.peak = peak; self.offPeak = offPeak; self.peakAt = peakAt; self.offPeakAt = offPeakAt
        self.recentPeak = recentPeak; self.recentOffPeak = recentOffPeak
    }

    init(_ p: PersistedFactors) {
        self.init(peak: p.peak, offPeak: p.offPeak,
                  peakAt: p.peakAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                  offPeakAt: p.offPeakAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                  recentPeak: p.recentPeak, recentOffPeak: p.recentOffPeak)
    }

    var persisted: PersistedFactors {
        var p = PersistedFactors()
        p.peak = peak; p.offPeak = offPeak
        p.peakAt = peakAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        p.offPeakAt = offPeakAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        p.recentPeak = recentPeak; p.recentOffPeak = recentOffPeak
        return p
    }

    func factor(_ peak: Bool) -> Double? { peak ? self.peak : offPeak }
    func recent(_ peak: Bool) -> [Double] { peak ? recentPeak : recentOffPeak }
}

public enum ForecastEngine {
    static let maxRecentFactors = 8
    /// Максимальная длина валидного интервала: дольше — это не минутная серия.
    static let maxIntervalGapMs: Int64 = 30 * 60_000

    /// «Свежий» фактор по спеке §4.1: есть значение, откалиброванное за 7 дней.
    /// Внутренний: сигнатура оперирует внутренним CalibrationFactors, наружу
    /// тип не выставляем (тесты через @testable, задачи 7–8 в этом же модуле).
    static func isFresh(_ f: CalibrationFactors, peak: Bool, now: Date) -> Bool {
        guard let value = f.factor(peak), value > 0 else { return false }
        guard let at = peak ? f.peakAt : f.offPeakAt else { return false }
        return now.timeIntervalSince(at) < 7 * 24 * 3600
    }

    /// Δкредиты/Δтокены по соседним сэмплам минутной серии, раздельно по
    /// режимам; выбросы гасятся медианой последних 8 факторов. Интервал валиден,
    /// если он не длиннее 30 мин: длинная пауза — демон не опрашивал (серия
    /// сфолдилась/приложение было закрыто), делить такой скачок нельзя. Возраст
    /// самого интервала не ограничен: пик 14:00–18:00 UTC+8 случается раз в день,
    /// пиковый фактор всегда собирается из «старых» интервалов.
    static func calibrate(previous: CalibrationFactors, samples: [QuotaSample],
                          buckets: [TokenBucket], now: Date) -> CalibrationFactors {
        var f = previous
        let byTime = samples.sorted { $0.t < $1.t }
        for (a, b) in zip(byTime, byTime.dropFirst())
        where b.t > a.t && b.t - a.t <= maxIntervalGapMs {
            let dCredits = b.fiveUsed - a.fiveUsed
            guard dCredits >= 0 else { continue }
            let dTokens = buckets.filter { $0.m > a.t && $0.m <= b.t }.reduce(0.0) { $0 + $1.total }
            guard dTokens > 0 else { continue }
            let factor = dCredits / dTokens
            let peak = PeakSchedule.isPeak(at: Date(timeIntervalSince1970: Double(b.t) / 1000))
            var recent = f.recent(peak) + [factor]
            if recent.count > maxRecentFactors { recent.removeFirst(recent.count - maxRecentFactors) }
            let median = recent.sorted()[recent.count / 2]
            if peak { f.peak = median; f.peakAt = Date(timeIntervalSince1970: Double(b.t) / 1000); f.recentPeak = recent }
            else { f.offPeak = median; f.offPeakAt = Date(timeIntervalSince1970: Double(b.t) / 1000); f.recentOffPeak = recent }
        }
        return f
    }
}
