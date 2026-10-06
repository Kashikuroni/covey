import Foundation
import CoveyKit

/// Одно токен-событие: assistant-запись транскрипта, уже очищенная парсером.
public struct TokenEvent: Sendable, Equatable {
    public let t: Date
    public let sessionKey: String
    public let model: String
    public let isSidechain: Bool
    public let input, output, cacheCreation, cacheRead: Double
    public init(t: Date, sessionKey: String, model: String, isSidechain: Bool,
                input: Double, output: Double, cacheCreation: Double, cacheRead: Double) {
        self.t = t; self.sessionKey = sessionKey; self.model = model; self.isSidechain = isSidechain
        self.input = input; self.output = output
        self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
    }
    public var total: Double { input + output + cacheCreation + cacheRead }
}

/// Скользящие окна поверх минутных вёдер. Хранение — вёдра `TokenBucket`:
/// одна ячейка на (минута × сессия × модель × sidechain), иначе неделя
/// событий не влезает ни в память, ни в JSON. Все выборки линейные — объём
/// (десятки тысяч вёдер) это позволяет, а код остаётся прозрачным.
public final class TokenAggregator {
    private var storage: [TokenBucket]
    private let keep: TimeInterval = 8 * 24 * 3600

    public init(buckets: [TokenBucket] = []) { self.storage = buckets }

    public func ingest(_ e: TokenEvent) {
        let m = Int64(e.t.timeIntervalSince1970 * 1000)
        let minute = m - m % 60_000
        if let i = storage.firstIndex(where: { $0.m == minute && $0.s == e.sessionKey
                && $0.model == e.model && $0.x == e.isSidechain }) {
            storage[i].input += e.input; storage[i].output += e.output
            storage[i].cacheCreation += e.cacheCreation; storage[i].cacheRead += e.cacheRead
        } else {
            storage.append(TokenBucket(m: minute, s: e.sessionKey, model: e.model,
                                       x: e.isSidechain, input: e.input, output: e.output,
                                       cacheCreation: e.cacheCreation, cacheRead: e.cacheRead))
        }
        let cutoff = m - Int64(keep * 1000)
        storage.removeAll { $0.m < cutoff }
    }

    public var buckets: [TokenBucket] { storage }

    public func sessionRates(now: Date, idle: TimeInterval)
        -> [(key: String, tokensPerHour: Double, active: Bool, windowTotal: Double,
             sidechainShare: Double, cacheHit: Double?)] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let idleMs = Int64(idle * 1000)
        let fifteenMin = nowMs - 15 * 60_000
        let bySession = Dictionary(grouping: storage, by: \.s)
        return bySession.compactMap { key, list -> (key: String, tokensPerHour: Double, active: Bool, windowTotal: Double, sidechainShare: Double, cacheHit: Double?)? in
            // Темпы GLM-квоты — только GLM-сессии; claude/gpt-транскрипты
            // собираются (вёдра/журнал/таблицы), но квоту z.ai не жгут.
            guard list.contains(where: { TokenUsageScanner.isGLMModel($0.model) }) else {
                return nil
            }
            let last = list.map(\.m).max() ?? 0
            let recent = list.filter { $0.m >= fifteenMin }
            let recentTotal = recent.reduce(0.0) { $0 + $1.total }
            let sidechain = recent.reduce(0.0) { $0 + ($1.x ? $1.total : 0) }
            // Cache hit сессии — по тем же свежим 15 минутам (этап 1).
            let cr = recent.reduce(0.0) { $0 + $1.cacheRead }
            let denom = recent.reduce(0.0) { $0 + $1.cacheRead + $1.input + $1.cacheCreation }
            // windowTotal — всё хранимое (прун 8д ≥ 7д окна), idle не режет.
            return (key, recentTotal * 4, last >= nowMs - idleMs,
                    list.reduce(0.0) { $0 + $1.total },
                    recentTotal > 0 ? sidechain / recentTotal : 0,
                    denom > 0 ? cr / denom : nil)
        }
    }

    public func accountTokensPerHour(now: Date, idle: TimeInterval) -> Double {
        sessionRates(now: now, idle: idle).filter(\.active).reduce(0.0) { $0 + $1.tokensPerHour }
    }

    public func totals(since: Date) -> GLMTokenUsage {
        let cutoff = Int64(since.timeIntervalSince1970 * 1000)
        var out = GLMTokenUsage()
        for b in storage where b.m >= cutoff {
            out.input += b.input; out.output += b.output
            out.cacheCreation += b.cacheCreation; out.cacheRead += b.cacheRead
        }
        return out
    }

    public func perModel(windowStart: Date, hourStart: Date) -> [GLMModelUsage] {
        let wCut = Int64(windowStart.timeIntervalSince1970 * 1000)
        let hCut = Int64(hourStart.timeIntervalSince1970 * 1000)
        var byModel: [String: (w: GLMTokenUsage, h: GLMTokenUsage)] = [:]
        for b in storage {
            var entry = byModel[b.model] ?? (GLMTokenUsage(), GLMTokenUsage())
            if b.m >= wCut {
                entry.w.input += b.input; entry.w.output += b.output
                entry.w.cacheCreation += b.cacheCreation; entry.w.cacheRead += b.cacheRead
            }
            if b.m >= hCut {
                entry.h.input += b.input; entry.h.output += b.output
                entry.h.cacheCreation += b.cacheCreation; entry.h.cacheRead += b.cacheRead
            }
            byModel[b.model] = entry
        }
        return byModel.map { GLMModelUsage(model: $0.key, window: $0.value.w, lastHour: $0.value.h) }
            .sorted { $0.model < $1.model }
    }

    /// Токены по локальным дням × моделям за последние `days` дней —
    /// столбчатый график 7d. models — total, usage — компоненты биллинга.
    public func perDay(now: Date, days: Int) -> [GLMDayUsage] {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: now.addingTimeInterval(-Double(max(0, days - 1)) * 24 * 3600))
        let cutMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        var out: [Int64: (models: [String: Double], usage: [String: GLMTokenUsage])] = [:]
        for b in storage where b.m >= cutMs {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(b.m) / 1000))
            let key = Int64(day.timeIntervalSince1970 * 1000)
            var entry = out[key] ?? ([:], [:])
            entry.models[b.model, default: 0] += b.total
            var u = entry.usage[b.model] ?? GLMTokenUsage()
            u.input += b.input; u.output += b.output
            u.cacheCreation += b.cacheCreation; u.cacheRead += b.cacheRead
            entry.usage[b.model] = u
            out[key] = entry
        }
        return out.sorted { $0.key < $1.key }
            .map { GLMDayUsage(t: $0.key, models: $0.value.models, usage: $0.value.usage) }
    }

    /// Пожизненные тоталы по сессиям из живых вёдер (этап 0: журнал
    /// стоимости). byModel — total (совместимость), usage — компоненты
    /// биллинга для честного $. Вёдра прунятся — стор мержит монотонно.
    public func sessionTotals()
        -> [String: (first: Int64, last: Int64,
                     byModel: [String: Double], usage: [String: GLMTokenUsage])] {
        var out: [String: (first: Int64, last: Int64,
                           byModel: [String: Double], usage: [String: GLMTokenUsage])] = [:]
        for b in storage {
            var rec = out[b.s] ?? (b.m, b.m, [:], [:])
            rec.first = min(rec.first, b.m)
            rec.last = max(rec.last, b.m)
            rec.byModel[b.model, default: 0] += b.total
            var u = rec.usage[b.model] ?? GLMTokenUsage()
            u.input += b.input; u.output += b.output
            u.cacheCreation += b.cacheCreation; u.cacheRead += b.cacheRead
            rec.usage[b.model] = u
            out[b.s] = rec
        }
        return out
    }

    /// Токены по часам (t = начало часа) из живых вёдер (этап 0: теплокарта).
    public func hourTotals(now: Date) -> [GLMSeriesPoint] {
        var out: [Int64: Double] = [:]
        for b in storage {
            out[b.m - b.m % 3_600_000, default: 0] += b.total
        }
        return out.sorted { $0.key < $1.key }
            .map { GLMSeriesPoint(t: $0.key, used: $0.value) }
    }

    /// Час × модель × компоненты биллинга за последние `days` дней (§spend:
    /// $-линия дня). Вёдра живут 8 дней — столько же и история.
    public func perHour(now: Date, days: Int) -> [GLMHourUsage] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
        var out: [Int64: [String: GLMTokenUsage]] = [:]
        for b in storage where b.m >= cutoff {
            let hour = b.m - b.m % 3_600_000
            var byModel = out[hour] ?? [:]
            var u = byModel[b.model] ?? GLMTokenUsage()
            u.input += b.input; u.output += b.output
            u.cacheCreation += b.cacheCreation; u.cacheRead += b.cacheRead
            byModel[b.model] = u
            out[hour] = byModel
        }
        return out.sorted { $0.key < $1.key }
            .map { GLMHourUsage(t: $0.key, usage: $0.value) }
    }
}
