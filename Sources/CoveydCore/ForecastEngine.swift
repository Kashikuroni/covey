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

/// Источник оценки текущего темпа сжигания кредитов (спека §4.2).
public enum RateSource: String, Equatable, Sendable { case instant, recent, windowAverage }

/// Темп расхода квоты аккаунта: кредиты/ч и лежащие в их основе токены/ч.
public struct AccountRate: Equatable, Sendable {
    public var creditsPerHour: Double
    public var tokensPerHour: Double
    public var source: RateSource
    public init(creditsPerHour: Double, tokensPerHour: Double, source: RateSource) {
        self.creditsPerHour = creditsPerHour; self.tokensPerHour = tokensPerHour; self.source = source
    }
}

extension ForecastEngine {
    /// Бленд трёх оценок §4.2: instant → recent → windowAverage.
    /// instant — Σ темпов активных сессий × свежий фактор текущего режима;
    /// свежесть нужна обоим режимам, как в project: иначе горизонт проецируется
    /// плоской ставкой, а instant дал бы projected = used (спека §4.1 — при
    /// некалиброванном режиме честные дельты квоты, не оптимизм).
    /// recent — медиана дельт `fiveUsed` минутной серии за последние 15 мин;
    /// windowAverage — usedSoFar за время от начала окна. Первая применимая
    /// оценка выигрывает; без данных — нулевая ставка с source: .windowAverage.
    /// Внутренний: сигнатура оперирует внутренним CalibrationFactors (как
    /// isFresh/calibrate); потребитель задачи 8 живёт в этом же модуле.
    static func creditRate(samples: [QuotaSample],
                           sessionRates: [(key: String, tokensPerHour: Double, active: Bool, windowTotal: Double, sidechainShare: Double)],
                           factors: CalibrationFactors, now: Date,
                           windowStart: Date, usedSoFar: Double) -> AccountRate {
        let tokensPerHour = sessionRates.filter(\.active).reduce(0.0) { $0 + $1.tokensPerHour }
        let peak = PeakSchedule.isPeak(at: now)
        if tokensPerHour > 0, isFresh(factors, peak: true, now: now),
           isFresh(factors, peak: false, now: now),
           let factor = factors.factor(peak) {
            return AccountRate(creditsPerHour: tokensPerHour * factor,
                               tokensPerHour: tokensPerHour, source: .instant)
        }
        let byTime = samples.sorted { $0.t < $1.t }
        let cutoff = now.addingTimeInterval(-15 * 60)
        let deltas: [Double] = zip(byTime, byTime.dropFirst()).compactMap { a, b in
            guard a.t >= Int64(cutoff.timeIntervalSince1970 * 1000), b.t > a.t else { return nil }
            let d = b.fiveUsed - a.fiveUsed
            return d >= 0 ? d / (Double(b.t - a.t) / 3_600_000) : nil
        }
        if !deltas.isEmpty {
            let median = deltas.sorted()[deltas.count / 2]
            return AccountRate(creditsPerHour: median, tokensPerHour: tokensPerHour, source: .recent)
        }
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed > 0, usedSoFar >= 0 {
            return AccountRate(creditsPerHour: usedSoFar / (elapsed / 3600),
                               tokensPerHour: tokensPerHour, source: .windowAverage)
        }
        return AccountRate(creditsPerHour: 0, tokensPerHour: tokensPerHour, source: .windowAverage)
    }
}

/// Настройки прогноза (значения приходят из CoveyConfig): учитывать ли
/// внешние сессии, порог «впритык» в % от total и порог «скоро сброс» в минутах.
public struct GLMForecastConfig: Equatable, Sendable {
    public var includeExternal: Bool
    public var marginPercent: Double
    public var imminentMinutes: Double
    public init(includeExternal: Bool = true, marginPercent: Double = 15, imminentMinutes: Double = 20) {
        self.includeExternal = includeExternal; self.marginPercent = marginPercent
        self.imminentMinutes = imminentMinutes
    }
}

extension ForecastEngine {
    /// Проекция одного квота-окна к resetAt. Агенты жгут токены независимо от
    /// времени суток, поэтому при свежих факторах обоих режимов горизонт
    /// [now, resetAt) режется на сегменты режима и каждый переводится в кредиты
    /// фактором своего режима; иначе — плоская ставка flatCreditsPerHour.
    /// Вердикт: idle — нет темпа; overflow — projected ≥ remaining; tight —
    /// запас < margin% от total; underuse — запас > underuse% от total; иначе
    /// fits. exhaustionAt/agentMinutes — по эффективной ставке горизонта
    /// (projected−used)/hours; nil при нулевой ставке. Внутренний: сигнатура
    /// оперирует внутренним CalibrationFactors (как isFresh/calibrate/creditRate).
    static func project(used: Double, total: Double, remaining: Double, resetAt: Date,
                        tokensPerHour: Double, flatCreditsPerHour: Double,
                        factors: CalibrationFactors, now: Date,
                        marginPercent: Double, underusePercent: Double) -> GLMWindowForecast {
        let hours = max(0, resetAt.timeIntervalSince(now) / 3600)
        var projected = used
        if hours > 0 {
            if isFresh(factors, peak: true, now: now), isFresh(factors, peak: false, now: now),
               tokensPerHour > 0 {
                for seg in PeakSchedule.segments(from: now, to: resetAt) where seg.duration > 0 {
                    projected += tokensPerHour * (seg.duration / 3600)
                        * (factors.factor(seg.peak) ?? 0)
                }
            } else {
                projected += flatCreditsPerHour * hours
            }
        }
        projected = max(projected, used)
        let delta = projected - used
        let effectiveRate = hours > 0 ? delta / hours : 0     // кредиты/ч по горизонту
        var verdict = GLMForecastVerdict.fits
        if tokensPerHour <= 0, flatCreditsPerHour <= 0 {
            verdict = .idle
        } else if projected >= remaining {
            verdict = .overflow
        } else if remaining - projected < total * marginPercent / 100 {
            verdict = .tight
        } else if remaining - projected > total * underusePercent / 100 {
            verdict = .underuse
        }
        let headroom = total > 0 ? 100 - projected / total * 100 : 0
        return GLMWindowForecast(
            verdict: verdict, projected: projected, remaining: remaining, total: total,
            resetAt: Int64(resetAt.timeIntervalSince1970 * 1000),
            exhaustionAt: effectiveRate > 0
                ? Int64((now.addingTimeInterval(remaining / effectiveRate * 3600))
                    .timeIntervalSince1970 * 1000) : nil,
            headroomPercent: headroom, rateCreditsPerHour: effectiveRate,
            agentMinutes: effectiveRate > 0 ? remaining / effectiveRate * 60 : nil)
    }

    /// Сборка прогноза для монитора (задача 9): калибровка → ставки сессий →
    /// проекция обоих окон → агенты/модели/серии/факторы/peakNow/nextFlipAt.
    /// Имена агентов, external и budgetMinutes резолвит вызывающий — здесь
    /// ключи сессий; creditsPerHour агента = 0 без свежего фактора текущего
    /// режима (UI v1 показывает токены). Внутренний по той же причине, что и
    /// project: сигнатура оперирует внутренним CalibrationFactors.
    static func build(fiveHours: GLMLimitWindow?, weekly: GLMLimitWindow?,
                      aggregator: TokenAggregator, store: QuotaSampleStore,
                      factors inFactors: CalibrationFactors, now: Date,
                      config: GLMForecastConfig) -> (forecast: GLMForecast, factors: CalibrationFactors) {
        var factors = calibrate(previous: inFactors, samples: store.minuteSeries(now: now, minutes: 30),
                                buckets: store.buckets, now: now)
        var out = GLMForecast()
        out.peakNow = PeakSchedule.isPeak(at: now)
        out.nextFlipAt = Int64(PeakSchedule.nextFlip(after: now).timeIntervalSince1970 * 1000)
        let rates = aggregator.sessionRates(now: now, idle: 600)
        let tokensPerHour = rates.filter(\.active).reduce(0.0) { $0 + $1.tokensPerHour }
        out.tokensPerHour = tokensPerHour
        out.factorPeak = factors.peak; out.factorOffPeak = factors.offPeak
        out.factorPeakAt = factors.peakAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        out.factorOffPeakAt = factors.offPeakAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        for (window, key) in [(fiveHours, "five"), (weekly, "week")] {
            guard let w = window else { continue }
            let duration: TimeInterval = key == "five" ? 5 * 3600 : 7 * 24 * 3600
            let start = Date(timeIntervalSince1970: Double(w.resetAt) / 1000)
                .addingTimeInterval(-duration)
            // weekly живёт в 5-мин вёдрах — дельты для «recent» берём оттуда.
            let series = key == "five" ? store.minuteSeries(now: now, minutes: 15)
                                       : store.weekSeries(now: now, days: 1)
            let rate = creditRate(samples: series, sessionRates: rates, factors: factors,
                                  now: now, windowStart: start, usedSoFar: w.used)
            let fc = project(used: w.used, total: w.total, remaining: w.remaining,
                             resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                             tokensPerHour: tokensPerHour,
                             flatCreditsPerHour: rate.source == .instant ? 0 : rate.creditsPerHour,
                             factors: factors, now: now,
                             marginPercent: config.marginPercent, underusePercent: 30)
            if key == "five" { out.fiveHours = fc } else { out.weekly = fc }
        }
        // Агенты: имена/external/budgetMinutes резолвит вызывающий (задача 9) — здесь ключи.
        out.agents = rates.map { r in
            GLMAgentForecast(name: r.key, external: false, active: r.active,
                             isSidechainMarked: r.sidechainShare > 0.5,
                             tokensPerHour: r.tokensPerHour,
                             creditsPerHour: r.tokensPerHour * (factors.factor(out.peakNow) ?? 0),
                             sharePercent: tokensPerHour > 0 ? r.tokensPerHour / tokensPerHour * 100 : 0,
                             budgetMinutes: nil)
        }
        let windowStart = fiveHours.map { w in
            Date(timeIntervalSince1970: Double(w.resetAt) / 1000).addingTimeInterval(-5 * 3600)
        } ?? now.addingTimeInterval(-7 * 24 * 3600)
        out.models = aggregator.perModel(windowStart: windowStart, hourStart: now.addingTimeInterval(-3600))
        out.fiveHourSeries = store.weekSeries(now: now, days: 7)
            .map { GLMSeriesPoint(t: $0.t, used: $0.fiveUsed) }
        out.weeklySeries = store.weekSeries(now: now, days: 7)
            .map { GLMSeriesPoint(t: $0.t, used: $0.weekUsed) }
        return (out, factors)
    }
}
