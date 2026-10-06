import Foundation
import CoveyKit

/// Incrementally normalizes Codex rollout lines into TraceEvents. Stateful:
/// carries the current model/effort/version across turns.
public struct CodexTraceAdapter {
    private var model: String?
    private var effort: String?
    private var version: String?
    public init() {}

    public mutating func consume(lines: [Data], seq: inout Int) -> [TraceEvent] {
        var out: [TraceEvent] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            // Источник времени — верхнеуровневый timestamp строки rollout;
            // без него остаётся время разбора.
            let ts = CodexTranscript.timestamp(obj) ?? Date()
            out += events(topType: obj["type"] as? String, payload: payload,
                          ts: ts, seq: &seq)
        }
        return out
    }

    private mutating func events(topType: String?, payload: [String: Any],
                                 ts: Date, seq: inout Int) -> [TraceEvent] {
        switch topType {
        case "session_meta":
            version = payload["cli_version"] as? String ?? version
            return []
        case "turn_context":
            model = (payload["model"] as? String) ?? model
            effort = (payload["effort"] as? String) ?? effort
            return []
        case "response_item":
            return responseItem(payload, ts: ts, seq: &seq)
        case "event_msg":
            return eventMsg(payload, ts: ts, seq: &seq)
        default:
            return []
        }
    }

    private func responseItem(_ p: [String: Any], ts: Date, seq: inout Int) -> [TraceEvent] {
        func make(_ kind: TraceEvent.Kind, _ raw: Any) -> TraceEvent {
            defer { seq += 1 }
            return TraceEvent(seq: seq, agent: .main, cli: .codex, cliVersion: version,
                model: model, effort: effort, timestamp: ts, kind: kind, raw: json(raw))
        }
        switch p["type"] as? String {
        case "custom_tool_call", "function_call":
            let name = p["name"] as? String ?? "?"
            let id = p["call_id"] as? String ?? ""
            let raw = p["input"] ?? p["arguments"] ?? p
            return [make(.toolCall(id: id, name: name), raw)]
        case "custom_tool_call_output", "function_call_output":
            let id = p["call_id"] as? String ?? ""
            let text = (p["output"] as? String) ?? ""
            return [make(.toolResult(callId: id, isError: false, preview: preview(text)), p)]
        case "reasoning":
            let text = ((p["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
                .joined(separator: "\n")) ?? ""
            return [make(.thinking(preview: preview(text)), p)]
        default:
            return []
        }
    }

    private func eventMsg(_ p: [String: Any], ts: Date, seq: inout Int) -> [TraceEvent] {
        func make(_ kind: TraceEvent.Kind, _ raw: Any) -> TraceEvent {
            defer { seq += 1 }
            return TraceEvent(seq: seq, agent: .main, cli: .codex, cliVersion: version,
                model: model, effort: effort, timestamp: ts, kind: kind, raw: json(raw))
        }
        switch p["type"] as? String {
        case "task_started":  return [make(.turnStarted, p)]
        case "task_complete": return [make(.turnCompleted(durationMs: nil), p)]
        case "token_count":
            var out: [TraceEvent] = []
            if let info = p["info"] as? [String: Any],
               let raw = CodexTranscript.rawTokenUsage(info) {
                let usage = TraceEvent.TokenUsage(
                    input: Int(raw.input), output: Int(raw.output),
                    cacheRead: Int(raw.cached), cacheCreate: 0,
                    reasoning: Int(raw.reasoning),
                    total: Int(raw.total),
                    contextWindow: raw.contextWindow.map(Int.init))
                out.append(make(.tokenUsage(usage), info))
            }
            if let limits = p["rate_limits"] as? [String: Any],
               let primary = limits["primary"] as? [String: Any],
               let pct = (primary["used_percent"] as? NSNumber)?.doubleValue {
                let resets = (primary["resets_at"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue) }
                out.append(make(.rateLimit(usedPercent: pct, resetsAt: resets,
                    plan: p["plan_type"] as? String), limits))
            }
            return out
        case "patch_apply_end":
            guard let changes = p["changes"] as? [String: [String: Any]] else { return [] }
            return changes.sorted { $0.key < $1.key }.map { path, delta in
                make(.fileEdit(path: path,
                    added: (delta["added"] as? NSNumber)?.intValue ?? 0,
                    removed: (delta["removed"] as? NSNumber)?.intValue ?? 0,
                    diff: delta["diff"] as? String), delta)
            }
        default:
            return []
        }
    }

    private func preview(_ s: String, _ cap: Int = 200) -> String {
        s.count <= cap ? s : String(s.prefix(cap)) + "…"
    }
    private func json(_ any: Any) -> String {
        if let s = any as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: any,
                options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
