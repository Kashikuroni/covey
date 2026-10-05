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
        -> [(key: String, tokensPerHour: Double, active: Bool, windowTotal: Double, sidechainShare: Double)] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let idleMs = Int64(idle * 1000)
        let fifteenMin = nowMs - 15 * 60_000
        let bySession = Dictionary(grouping: storage, by: \.s)
        return bySession.map { key, list in
            let last = list.map(\.m).max() ?? 0
            let recent = list.filter { $0.m >= fifteenMin }
            let recentTotal = recent.reduce(0.0) { $0 + $1.total }
            let sidechain = recent.reduce(0.0) { $0 + ($1.x ? $1.total : 0) }
            // windowTotal — всё хранимое (прун 8д ≥ 7д окна), idle не режет.
            return (key, recentTotal * 4, last >= nowMs - idleMs,
                    list.reduce(0.0) { $0 + $1.total },
                    recentTotal > 0 ? sidechain / recentTotal : 0)
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
}
