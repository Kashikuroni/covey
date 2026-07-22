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
            out += events(topType: obj["type"] as? String, payload: payload, seq: &seq)
        }
        return out
    }

    private mutating func events(topType: String?, payload: [String: Any],
                                 seq: inout Int) -> [TraceEvent] {
        switch topType {
        case "session_meta":
            version = payload["cli_version"] as? String ?? version
            return []
        case "turn_context":
            model = (payload["model"] as? String) ?? model
            effort = (payload["effort"] as? String) ?? effort
            return []
        case "response_item":
            return responseItem(payload, seq: &seq)
        default:
            return []
        }
    }

    private func responseItem(_ p: [String: Any], seq: inout Int) -> [TraceEvent] {
        let ts = Date()
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
