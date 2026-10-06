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

/// Источник оценки текущего темпа сжигания кредитов (спека §4.2 + §7d-нормализация).
public enum RateSource: String, Equatable, Sendable { case instant, recent, windowAverage, daily }

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
                           sessionRates: [(key: String, tokensPerHour: Double, active: Bool, windowTotal: Double,
                                           sidechainShare: Double, cacheHit: Double?)],
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

    // MARK: - Нормализация недельного окна (§7d-скачки)

    /// Валидные интервалы серии: 0 < dt ≤ 30 мин, дельта ≥ 0, не пересекает
    /// разрыв опроса. Общий фильтр EMA-ставки и процентильной полосы.
    private static func validDeltas(_ samples: [QuotaSample], gaps: [Range<Double>])
        -> [(rate: Double, midMs: Double, dtMs: Double)] {
        let byTime = samples.sorted { $0.t < $1.t }
        return zip(byTime, byTime.dropFirst()).compactMap { a, b in
            let dt = Double(b.t - a.t)
            guard dt > 0, dt <= Double(maxIntervalGapMs) else { return nil }
            let aT = Double(a.t), bT = Double(b.t)
            guard !gaps.contains(where: { aT < $0.upperBound && $0.lowerBound < bT }) else { return nil }
            let d = b.weekUsed - a.weekUsed
            guard d >= 0 else { return nil }
            return (d / (dt / 3_600_000), (aT + bT) / 2, dt)
        }
    }

    /// Недельная ставка (§7d): EMA дельт weekUsed с τ=24ч — окно сглаживания
    /// масштабировано горизонтом (~неделя/8), 15-мин всплеск весит доли
    /// процента. Минимум 6ч валидной истории; меньше — среднее окна без
    /// времени разрывов. Горизонт недели — не мгновенный темп: instant
    /// остаётся у 5h-окна.
    static func weeklyRate(samples: [QuotaSample], gaps: [Range<Double>],
                           windowStart: Date, usedSoFar: Double, now: Date) -> AccountRate {
        let nowMs = Double(now.timeIntervalSince1970 * 1000)
        let tau = 24 * 3_600_000.0
        var num = 0.0, den = 0.0, covered = 0.0
        for d in validDeltas(samples, gaps: gaps) {
            let w = exp(-(nowMs - d.midMs) / tau)
            num += w * d.rate
            den += w
            covered += d.dtMs
        }
        if den > 0, covered >= 6 * 3_600_000 {
            return AccountRate(creditsPerHour: num / den, tokensPerHour: 0, source: .daily)
        }
        let startMs = Double(windowStart.timeIntervalSince1970 * 1000)
        let spanTotal = max(0, nowMs - startMs)
        let gapTime = gaps.reduce(0.0) { acc, g in
            acc + min(max(0, min(g.upperBound, nowMs) - max(g.lowerBound, startMs)), spanTotal)
        }
        let span = max(0, spanTotal - gapTime)
        if span > 0, usedSoFar >= 0 {
            return AccountRate(creditsPerHour: usedSoFar / (span / 3_600_000),
                               tokensPerHour: 0, source: .windowAverage)
        }
        return AccountRate(creditsPerHour: 0, tokensPerHour: 0, source: .windowAverage)
    }

    /// Полоса неопределённости недельной проекции: p50/p90 темпов из того же
    /// распределения валидных дельт, спроецированные на остаток окна.
    static func weeklyBand(samples: [QuotaSample], gaps: [Range<Double>],
                           resetAt: Date, used: Double, now: Date) -> (p50: Double, p90: Double)? {
        let rates = validDeltas(samples, gaps: gaps).map(\.rate)
        guard rates.count >= 24 else { return nil }
        let sorted = rates.sorted()
        let q = { (p: Double) in sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
        let hours = max(0, resetAt.timeIntervalSince(now) / 3600)
        return (used + q(0.5) * hours, used + q(0.9) * hours)
    }

    /// Покрытие мониторинга (этап 1): доля времени окна без разрывов опроса —
    /// доверие к средним и индикатор «демона не было».
    static func dataCoverage(gaps: [Range<Double>], windowStart: Date, now: Date) -> Double? {
        let startMs = Double(windowStart.timeIntervalSince1970 * 1000)
        let nowMs = Double(now.timeIntervalSince1970 * 1000)
        let span = nowMs - startMs
        guard span > 0 else { return nil }
        let gapTime = gaps.reduce(0.0) { acc, g in
            acc + min(max(0, min(g.upperBound, nowMs) - max(g.lowerBound, startMs)), span)
        }
        return max(0, 1 - gapTime / span)
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
        let factors = calibrate(previous: inFactors, samples: store.minuteSeries(now: now, minutes: 30),
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
            if key == "five" {
                let rate = creditRate(samples: store.minuteSeries(now: now, minutes: 15),
                                      sessionRates: rates, factors: factors,
                                      now: now, windowStart: start, usedSoFar: w.used)
                out.fiveHours = project(used: w.used, total: w.total, remaining: w.remaining,
                                        resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                        tokensPerHour: tokensPerHour,
                                        flatCreditsPerHour: rate.source == .instant ? 0 : rate.creditsPerHour,
                                        factors: factors, now: now,
                                        marginPercent: config.marginPercent, underusePercent: 30)
            } else {
                // §7d: горизонт недели — не мгновенный темп. EMA(τ=24ч) дельт
                // weekUsed + полоса p50/p90; instant/recent остаются у 5h.
                let week = store.weekSeries(now: now, days: 7)
                let rate = weeklyRate(samples: week, gaps: store.gapRanges,
                                      windowStart: start, usedSoFar: w.used, now: now)
                var fc = project(used: w.used, total: w.total, remaining: w.remaining,
                                 resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                 tokensPerHour: 0,
                                 flatCreditsPerHour: rate.creditsPerHour,
                                 factors: CalibrationFactors(), now: now,
                                 marginPercent: config.marginPercent, underusePercent: 30)
                if let band = weeklyBand(samples: week, gaps: store.gapRanges,
                                         resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                         used: w.used, now: now) {
                    fc.projectedP50 = band.p50
                    fc.projectedP90 = band.p90
                }
                out.weekly = fc
            }
        }
        // Агенты: имена/external/budgetMinutes резолвит вызывающий (задача 9) — здесь ключи.
        // id = ключ сессии: после декорирования имена могут совпасть (общий проект).
        out.agents = rates.map { r in
            let ctx = store.lastContext[r.key]
            return GLMAgentForecast(name: r.key, id: r.key, external: false, active: r.active,
                             isSidechainMarked: r.sidechainShare > 0.5,
                             tokensPerHour: r.tokensPerHour,
                             creditsPerHour: r.tokensPerHour * (factors.factor(out.peakNow) ?? 0),
                             sharePercent: tokensPerHour > 0 ? r.tokensPerHour / tokensPerHour * 100 : 0,
                             budgetMinutes: nil,
                             cacheHit: r.cacheHit,
                             sidechainShare: r.sidechainShare,
                             contextTokens: ctx?.tokens,
                             contextDeltaPerTurn: ctx?.deltaPerTurn)
        }
        let windowStart = fiveHours.map { w in
            Date(timeIntervalSince1970: Double(w.resetAt) / 1000).addingTimeInterval(-5 * 3600)
        } ?? now.addingTimeInterval(-7 * 24 * 3600)
        out.models = aggregator.perModel(windowStart: windowStart, hourStart: now.addingTimeInterval(-3600))
        out.modelDaily = store.modelDays       // год дневных вёдер из стора (§график)
        out.fiveHourSeries = store.weekSeries(now: now, days: 7)
            .map { GLMSeriesPoint(t: $0.t, used: $0.fiveUsed) }
        out.weeklySeries = store.weekSeries(now: now, days: 7)
            .map { GLMSeriesPoint(t: $0.t, used: $0.weekUsed) }
        out.coverage7d = dataCoverage(gaps: store.gapRanges,
                                      windowStart: now.addingTimeInterval(-7 * 24 * 3600),
                                      now: now)
        return (out, factors)
    }
}
