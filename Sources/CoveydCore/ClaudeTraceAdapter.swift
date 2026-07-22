import Foundation
import CoveyKit

/// Incrementally normalizes Claude Code transcript lines into TraceEvents.
/// Stateful across ticks: tracks subagent grouping.
public struct ClaudeTraceAdapter {
    private var subagents: [String: TraceEvent.AgentRef] = [:]  // uuid -> agent
    public init() {}

    public mutating func consume(lines: [Data], seq: inout Int) -> [TraceEvent] {
        var out: [TraceEvent] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            out += events(from: obj, seq: &seq)
        }
        return out
    }

    private mutating func events(from obj: [String: Any], seq: inout Int) -> [TraceEvent] {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any] else { return [] }
        let version = obj["version"] as? String
        let model = message["model"] as? String
        let effort = obj["effort"] as? String
        let ts = timestamp(obj["timestamp"] as? String)
        var out: [TraceEvent] = []
        func make(_ kind: TraceEvent.Kind, _ raw: String) -> TraceEvent {
            defer { seq += 1 }
            return TraceEvent(seq: seq, agent: .main, cli: .claudeCode,
                              cliVersion: version, model: model, effort: effort,
                              timestamp: ts, kind: kind, raw: raw)
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                out.append(make(.assistantText(preview: preview(text)), json(block)))
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "?"
                out.append(make(.toolCall(id: id, name: name),
                                json(block["input"] ?? [:])))
            default: break
            }
        }
        if let usage = message["usage"] as? [String: Any] {
            out.append(make(.tokenUsage(tokenUsage(usage)), json(usage)))
        }
        return out
    }

    private func tokenUsage(_ u: [String: Any]) -> TraceEvent.TokenUsage {
        func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let input = int("input_tokens"), output = int("output_tokens")
        let cacheRead = int("cache_read_input_tokens")
        let cacheCreate = int("cache_creation_input_tokens")
        return .init(input: input, output: output, cacheRead: cacheRead,
                     cacheCreate: cacheCreate, reasoning: 0,
                     total: input + output + cacheRead + cacheCreate)
    }

    private func preview(_ s: String, _ cap: Int = 200) -> String {
        s.count <= cap ? s : String(s.prefix(cap)) + "…"
    }

    private func json(_ any: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any,
                options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func timestamp(_ iso: String?) -> Date {
        guard let iso else { return Date() }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
    }
}
