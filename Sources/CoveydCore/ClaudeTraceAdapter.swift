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
        let agent = resolveAgent(obj)
        let ts = timestamp(obj["timestamp"] as? String)
        let type = obj["type"] as? String

        if type == "user", let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            var out: [TraceEvent] = []
            for block in content where block["type"] as? String == "tool_result" {
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                let text = resultText(block["content"])
                defer { seq += 1 }
                out.append(TraceEvent(seq: seq, agent: agent, cli: .claudeCode,
                    timestamp: ts, kind: .toolResult(callId: id, isError: isError,
                    preview: preview(text)), raw: json(block)))
            }
            return out
        }

        guard type == "assistant", let message = obj["message"] as? [String: Any]
        else { return [] }
        let version = obj["version"] as? String
        let model = message["model"] as? String
        let effort = obj["effort"] as? String
        var out: [TraceEvent] = []
        func make(_ kind: TraceEvent.Kind, _ raw: String) -> TraceEvent {
            defer { seq += 1 }
            return TraceEvent(seq: seq, agent: agent, cli: .claudeCode,
                cliVersion: version, model: model, effort: effort,
                timestamp: ts, kind: kind, raw: raw)
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                out.append(make(.assistantText(preview: preview(block["text"] as? String ?? "")), json(block)))
            case "thinking":
                out.append(make(.thinking(preview: preview(block["thinking"] as? String ?? "")), json(block)))
            case "tool_use":
                out.append(make(.toolCall(id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "?"), json(block["input"] ?? [:])))
            default: break
            }
        }
        if let usage = message["usage"] as? [String: Any] {
            out.append(make(.tokenUsage(tokenUsage(usage)), json(usage)))
        }
        return out
    }

    /// Sidechain entries belong to a subagent keyed by the root uuid of their
    /// parentUuid chain; non-sidechain entries are the main agent.
    private mutating func resolveAgent(_ obj: [String: Any]) -> TraceEvent.AgentRef {
        guard obj["isSidechain"] as? Bool == true else { return .main }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        if let parent = obj["parentUuid"] as? String, let inherited = subagents[parent] {
            subagents[uuid] = inherited
            return inherited
        }
        let ref = TraceEvent.AgentRef(id: uuid, label: "subagent")
        subagents[uuid] = ref
        return ref
    }

    private func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
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
