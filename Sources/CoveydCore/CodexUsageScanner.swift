import Foundation
import CoveyKit

/// Счётчики пропусков одного poll-а разбора rollout-строк. Содержимое
/// prompt/response не логируется и не сохраняется — только агрегаты.
public struct CodexUsageParseStats: Equatable, Sendable {
    public var malformed = 0
    public var missingTimestamp = 0
    public var missingModel = 0
    public var invalidUsage = 0
    public init() {}
}

/// Результат разбора пачки строк: события для агрегатора, курсорное
/// состояние (последняя модель, две последние context-точки) и статистика.
public struct CodexUsageParseResult: Equatable, Sendable {
    public var events: [TokenEvent]
    public var model: String?
    public var contexts: [CodexContextPoint]
    public var stats: CodexUsageParseStats

    public init(events: [TokenEvent] = [], model: String? = nil,
                contexts: [CodexContextPoint] = [],
                stats: CodexUsageParseStats = CodexUsageParseStats()) {
        self.events = events; self.model = model
        self.contexts = contexts; self.stats = stats
    }
}

/// Чистый stateful-парсер Codex rollout JSONL в `TokenEvent`-ы прогноза.
/// Нормализация — спека «Разбор Codex rollout»: uncached input =
/// `input_tokens − cached_input_tokens` (cached — подмножество input),
/// cached становится cache read, reasoning не прибавляется повторно, поэтому
/// нормализованный total равен исходному `input_tokens + output_tokens`.
/// Читается только `last_token_usage`; кумулятивный `total_token_usage`
/// игнорируется. Событие без timestamp/model/ненулевой usage пропускается —
/// `Date()` для отсутствующего timestamp не изобретается.
public enum CodexUsageScanner {
    public static func parse(lines: [Data], sessionKey: String,
                             initialModel: String?) -> CodexUsageParseResult {
        var model = initialModel
        var events: [TokenEvent] = []
        var contexts: [CodexContextPoint] = []
        var stats = CodexUsageParseStats()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                stats.malformed += 1
                continue
            }
            switch obj["type"] as? String {
            case "turn_context":
                if let payload = obj["payload"] as? [String: Any],
                   let next = payload["model"] as? String, !next.isEmpty {
                    model = next
                }
            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let raw = CodexTranscript.rawTokenUsage(info) else { continue }
                guard let ts = CodexTranscript.timestamp(obj) else {
                    stats.missingTimestamp += 1
                    continue
                }
                guard let model, !model.isEmpty else {
                    stats.missingModel += 1
                    continue
                }
                let uncached = max(0, raw.input - raw.cached)
                guard uncached + raw.cached + raw.output > 0 else {
                    stats.invalidUsage += 1
                    continue
                }
                events.append(TokenEvent(t: ts, sessionKey: sessionKey, model: model,
                                         isSidechain: false,
                                         input: uncached, output: raw.output,
                                         cacheCreation: 0, cacheRead: raw.cached))
                contexts.append(CodexContextPoint(
                    tokens: raw.input,
                    t: Int64(ts.timeIntervalSince1970 * 1000)))
                if contexts.count > 2 { contexts.removeFirst(contexts.count - 2) }
            default:
                continue
            }
        }
        return CodexUsageParseResult(events: events, model: model,
                                     contexts: contexts, stats: stats)
    }
}
