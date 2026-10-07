import Foundation
import CoveyKit

/// Пороги прогноза Codex-квоты. marginPercent — общий с GLM «запас» tight-верdict'а;
/// staleAfter — сэмпл старше этого считается устаревшим; maxIntervalGap —
/// дельта через паузу длиннее этого не участвует в rate.
public struct CodexForecastConfig: Equatable, Sendable {
    public var marginPercent: Double
    public var staleAfter: TimeInterval
    public var maxIntervalGap: TimeInterval
    public init(marginPercent: Double = 15,
                staleAfter: TimeInterval = 180,
                maxIntervalGap: TimeInterval = 180) {
        self.marginPercent = marginPercent
        self.staleAfter = staleAfter
        self.maxIntervalGap = maxIntervalGap
    }
}

/// Чистый движок прогноза Codex rate-limit окон (этап 2). Вход — слитый
/// снапшот плюс персистентная история сэмплов; токен-вёдра, GPT-сессии и
/// GLM-факторы сознательно не потребляются: rate-limit snapshot — единственный
/// источник расхода аккаунта.
///
/// Внутри (bucketID, windowKey) работает только активный reset-сегмент:
/// смена resetAt, падение процента или невалидное значение начинают новый.
/// Rate — только по валидным интервалам (0 < dt ≤ maxIntervalGap, неотрицательная
/// дельта); нулевые интервалы сохраняются, чтобы honest idle отличался от
/// отсутствия калибровки.
public enum CodexForecastEngine {
    private static let shortWindowMaxMinutes = 1_440
    private static let recentIntervalWindowMs: Int64 = 15 * 60_000
    private static let weeklyTauMs: Double = 24 * 3600 * 1000

    public static func build(snapshot: CodexRateLimitsSnapshot,
                             store: QuotaSampleStore, now: Date,
                             config: CodexForecastConfig) -> CodexForecast {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var windows: [CodexWindowForecast] = []
        for (id, bucket) in snapshot.buckets.sorted(by: { $0.key < $1.key }) {
            guard !bucket.windows.isEmpty else { continue }
            for slot in [(bucket.primary, CodexForecastWindowKey.primary),
                         (bucket.secondary, CodexForecastWindowKey.secondary)] {
                guard let current = slot.0 else { continue }
                let series = store.codexQuotaSeries(bucketID: id, windowKey: slot.1, now: now)
                windows.append(project(id: id, slot: slot.1, current: current,
                                       bucket: bucket, series: series,
                                       nowMs: nowMs, config: config))
            }
        }
        return CodexForecast(windows: windows.sorted(), updatedAt: nowMs)
    }

    private static func project(id: String, slot: CodexForecastWindowKey,
                                current: LabeledWindow, bucket: CodexRateLimitBucket,
                                series: [CodexQuotaSample], nowMs: Int64,
                                config: CodexForecastConfig) -> CodexWindowForecast {
        // Тот же префикс, что у CodexRateLimitBucket.windows и стора сэмплов.
        let label: String
        if id == "codex" {
            label = current.label
        } else if let name = bucket.name, !name.isEmpty {
            label = "\(name) \(current.label)"
        } else {
            label = "\(id) \(current.label)"
        }
        let usedPercent = current.window.utilization
        let resetAt = current.window.resetUnix
            .flatMap(QuotaSampleStore.resetSecondsToMs)
            ?? series.last?.resetAt
        let latestT = series.last?.t ?? nowMs
        let stale = nowMs - latestT > Int64(config.staleAfter * 1000)

        let segment = activeSegment(series)
        let intervals = validIntervals(segment, config: config) ?? []
        let calibrated = !segment.isEmpty && !intervals.isEmpty
        let longWindow = current.durationMinutes.map { $0 > shortWindowMaxMinutes }
            ?? (slot == .secondary)
        var rate: Double = 0
        var p50Rate: Double?
        var p90Rate: Double?
        if longWindow {
            let rates = intervals.map(\.ratePercentPerHour)
            if let ema = exponentialDecay(rates: intervals, nowMs: nowMs) {
                rate = ema
            }
            if !rates.isEmpty {
                p50Rate = percentile(rates.sorted(), 0.5)
                p90Rate = percentile(rates.sorted(), 0.9)
            }
        } else {
            let cutoff = nowMs - recentIntervalWindowMs
            let recent = intervals
                .filter { $0.endT >= cutoff }
                .map(\.ratePercentPerHour)
            if !recent.isEmpty { rate = median(recent.sorted()) }
        }

        let horizonHours: Double?
        if let resetAt, resetAt > nowMs {
            horizonHours = Double(resetAt - nowMs) / 3_600_000
        } else {
            horizonHours = nil
        }
        var verdict = CodexForecastVerdict.calibrating
        var projected = usedPercent
        var headroom = 100 - usedPercent
        var exhaustionAt: Int64?
        if calibrated, let horizon = horizonHours {
            projected = usedPercent + rate * horizon
            headroom = 100 - projected
            if rate <= 0 {
                verdict = .idle
            } else {
                if projected >= 100 {
                    verdict = .overflow
                } else if headroom < config.marginPercent {
                    verdict = .tight
                } else if headroom > 30 {
                    verdict = .underuse
                } else {
                    verdict = .fits
                }
                let hoursToExhaust = max(0, 100 - usedPercent) / rate
                exhaustionAt = nowMs + Int64((hoursToExhaust * 3_600_000).rounded())
            }
            if longWindow {
                p50Rate = p50Rate.map { usedPercent + $0 * horizon }
                p90Rate = p90Rate.map { usedPercent + $0 * horizon }
            }
        }

        return CodexWindowForecast(
            bucketID: id, windowKey: slot, label: label, verdict: verdict,
            usedPercent: usedPercent,
            projectedPercent: projected,
            projectedP50: longWindow ? p50Rate : nil,
            projectedP90: longWindow ? p90Rate : nil,
            headroomPercent: headroom,
            resetAt: resetAt, exhaustionAt: exhaustionAt,
            ratePercentPerHour: rate,
            sampleCount: segment.count, stale: stale)
    }

    // MARK: - сегменты и интервалы

    private struct Interval {
        var endT: Int64
        var ratePercentPerHour: Double
    }

    /// Активный reset-сегмент: хвост серии от последнего разрыва (смена
    /// resetAt, падение процента больше эпсилон, невалидное значение).
    private static func activeSegment(_ series: [CodexQuotaSample]) -> [CodexQuotaSample] {
        guard !series.isEmpty else { return [] }
        var start = 0
        for i in 1..<series.count {
            let previous = series[i - 1], current = series[i]
            let resetChanged = previous.resetAt != current.resetAt
            let fell = current.usedPercent < previous.usedPercent - 1e-6
            let invalid = !current.usedPercent.isFinite || current.usedPercent < 0
            if resetChanged || fell || invalid { start = i }
        }
        return Array(series[start...])
    }

    /// Валидные интервалы сегмента: 0 < dt ≤ maxIntervalGap, неотрицательная
    /// дельта. Нулевая дельта сохраняется (idle — данные, не пропуск).
    private static func validIntervals(_ segment: [CodexQuotaSample],
                                       config: CodexForecastConfig) -> [Interval]? {
        guard !segment.isEmpty else { return nil }
        var result: [Interval] = []
        let maxGapMs = Int64(config.maxIntervalGap * 1000)
        for i in 1..<segment.count {
            let previous = segment[i - 1], current = segment[i]
            let dt = current.t - previous.t
            guard dt > 0, dt <= maxGapMs else { continue }
            let delta = current.usedPercent - previous.usedPercent
            guard delta >= 0 else { continue }
            result.append(Interval(
                endT: current.t,
                ratePercentPerHour: delta / (Double(dt) / 3_600_000)))
        }
        return result
    }

    /// Time-decayed EMA (τ = 24ч) по валидным интервалам сегмента.
    private static func exponentialDecay(rates: [Interval], nowMs: Int64) -> Double? {
        guard !rates.isEmpty else { return nil }
        var weightSum = 0.0
        var valueSum = 0.0
        for interval in rates {
            let age = max(0, nowMs - interval.endT)
            let weight = exp(-Double(age) / weeklyTauMs)
            weightSum += weight
            valueSum += weight * interval.ratePercentPerHour
        }
        return weightSum > 0 ? valueSum / weightSum : nil
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Nearest-rank перцентиль по возрастающей выборке.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int(ceil(p * Double(sorted.count)))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
