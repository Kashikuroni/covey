import Foundation
import CoveyKit

/// The card taxonomy the redesigned trace panel renders. Each trace event maps
/// to exactly one kind; tool calls sub-classify by tool name.
enum TraceCardKind: Equatable {
    case bash, read, edit, usage, assistant, result, thinking, turn, generic
}

/// Pure presentation logic for the trace cards — classification, tool-input
/// parsing, split-diff, and the readable token table. Kept out of the view so
/// it is unit-tested.
enum TracePresenter {

    // MARK: - Classification

    static func kind(_ e: TraceEvent) -> TraceCardKind {
        switch e.kind {
        case .thinking: return .thinking
        case .assistantText: return .assistant
        case .tokenUsage: return .usage
        case .toolResult: return .result
        case .fileEdit: return .edit
        case .turnStarted, .turnCompleted: return .turn
        case .rateLimit, .webSearch, .other: return .generic
        case let .toolCall(_, name):
            switch toolFamily(name) {
            case .bash: return .bash
            case .read: return .read
            case .edit: return .edit
            case .generic: return .generic
            }
        }
    }

    enum ToolFamily { case bash, read, edit, generic }

    static func toolFamily(_ name: String) -> ToolFamily {
        let n = name.lowercased()
        if n == "bash" || n == "exec" || n == "shell" || n.hasPrefix("exec") { return .bash }
        if n == "read" || n == "read_file" { return .read }
        if ["edit", "write", "multiedit", "apply_patch", "update_plan"].contains(n) { return .edit }
        return .generic
    }

    // MARK: - Header

    static func label(_ e: TraceEvent) -> String {
        switch kind(e) {
        case .bash: return "Bash"
        case .read: return "Read"
        case .edit: return "Edit"
        case .usage: return "Usage"
        case .assistant: return "Assistant"
        case .result: return "Result"
        case .thinking: return "Thinking"
        case .turn: return turnLabel(e)
        case .generic:
            if case let .toolCall(_, name) = e.kind { return name }
            if case .webSearch = e.kind { return "Search" }
            if case let .other(l) = e.kind { return l }
            return "Event"
        }
    }

    private static func turnLabel(_ e: TraceEvent) -> String {
        if case .turnStarted = e.kind { return "Turn started" }
        return "Turn completed"
    }

    /// SF Symbol name for the card's badge glyph.
    static func symbol(_ e: TraceEvent) -> String {
        switch kind(e) {
        case .bash: return "terminal"
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .usage: return "circle.lefthalf.filled"
        case .assistant: return "quote.opening"
        case .result:
            if case let .toolResult(_, isError, _) = e.kind { return isError ? "xmark" : "checkmark" }
            return "checkmark"
        case .thinking: return "ellipsis"
        case .turn: return "diamond"
        case .generic: return "curlybraces"
        }
    }

    static func shortModel(_ model: String?) -> String {
        guard let m = model, !m.isEmpty else { return "" }
        return m.hasPrefix("claude") ? modelDisplayName(m) : m
    }

    static func meta(_ e: TraceEvent) -> String {
        switch kind(e) {
        case .bash: return "shell"
        case .read: return "read"
        case .edit: return "edit"
        case .usage:
            if case let .tokenUsage(u) = e.kind, let c = u.contextWindow, c > 0 {
                return "\(c / 1000)K ctx"
            }
            return "usage"
        case .result:
            if case let .toolResult(_, isError, _) = e.kind { return isError ? "error" : "ok" }
            return ""
        case .generic: return e.cli == .claudeCode ? "claude" : "codex"
        case .assistant, .turn, .thinking: return ""
        }
    }

    // MARK: - JSON helpers

    static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// The assistant/text body: the full text from the raw block, else the
    /// stored (capped) preview.
    static func textBody(_ raw: String, fallback: String) -> String {
        if let obj = jsonObject(raw), let t = obj["text"] as? String { return t }
        if let obj = jsonObject(raw), let t = obj["thinking"] as? String { return t }
        return fallback
    }

    // MARK: - Bash

    static func bashFields(_ raw: String) -> (command: String, why: String?) {
        if let obj = jsonObject(raw) {
            let cmd = (obj["command"] as? String) ?? (obj["cmd"] as? String)
            let why = obj["description"] as? String
            if let cmd, !cmd.isEmpty { return (cmd, why) }
        }
        return (raw, nil)   // Codex exec input is a bare string
    }

    // MARK: - Read

    static func readFields(_ raw: String) -> (path: String, offset: Int?, limit: Int?) {
        let obj = jsonObject(raw)
        let path = (obj?["file_path"] as? String) ?? (obj?["path"] as? String) ?? ""
        let offset = (obj?["offset"] as? NSNumber)?.intValue
        let limit = (obj?["limit"] as? NSNumber)?.intValue
        return (path, offset, limit)
    }

    /// "path/to/File.swift" -> ("File.swift", "path/to/").
    static func splitPath(_ path: String) -> (name: String, dir: String) {
        guard let slash = path.lastIndex(of: "/") else { return (path, "") }
        let name = String(path[path.index(after: slash)...])
        let dir = String(path[...slash])
        return (name, dir)
    }

    // MARK: - Edit / diff

    static func editFields(_ raw: String) -> (path: String, old: String, new: String)? {
        guard let obj = jsonObject(raw) else { return nil }
        let path = (obj["file_path"] as? String) ?? (obj["path"] as? String) ?? ""
        if let old = obj["old_string"] as? String, let new = obj["new_string"] as? String {
            return (path, old, new)
        }
        if let content = obj["content"] as? String {
            return (path, "", content)   // Write: whole file is new
        }
        return nil
    }

    struct DiffLine: Equatable {
        enum Kind: Equatable { case context, add, del }
        var num: Int?
        var kind: Kind
        var text: String
    }

    /// GitHub-style split diff: common leading/trailing lines become context on
    /// both sides; the changed middle is deletions (left) and additions (right).
    static func splitDiff(old: String, new: String)
        -> (left: [DiffLine], right: [DiffLine], added: Int, removed: Int) {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var p = 0
        while p < oldLines.count, p < newLines.count, oldLines[p] == newLines[p] { p += 1 }
        var s = 0
        while s < oldLines.count - p, s < newLines.count - p,
              oldLines[oldLines.count - 1 - s] == newLines[newLines.count - 1 - s] { s += 1 }
        let oldMid = Array(oldLines[p..<(oldLines.count - s)])
        let newMid = Array(newLines[p..<(newLines.count - s)])

        var left: [DiffLine] = [], right: [DiffLine] = []
        for i in 0..<p {
            left.append(.init(num: i + 1, kind: .context, text: oldLines[i]))
            right.append(.init(num: i + 1, kind: .context, text: newLines[i]))
        }
        for (i, line) in oldMid.enumerated() {
            left.append(.init(num: p + i + 1, kind: .del, text: line))
        }
        for (i, line) in newMid.enumerated() {
            right.append(.init(num: p + i + 1, kind: .add, text: line))
        }
        for i in 0..<s {
            let oi = oldLines.count - s + i, ni = newLines.count - s + i
            left.append(.init(num: oi + 1, kind: .context, text: oldLines[oi]))
            right.append(.init(num: ni + 1, kind: .context, text: newLines[ni]))
        }
        return (left, right, added: newMid.count, removed: oldMid.count)
    }

    // MARK: - Tokens

    struct TokenRow: Equatable { var label: String; var value: String; var sub: String }

    /// Thousands grouped with a thin space: 324308 -> "324 308".
    static func groupedNumber(_ n: Int) -> String {
        let digits = Array(String(abs(n)))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    static func tokenRows(_ u: TraceEvent.TokenUsage) -> [TokenRow] {
        var rows: [TokenRow] = [
            .init(label: "Новый ввод", value: groupedNumber(u.input), sub: "на входе"),
            .init(label: "Ответ модели", value: groupedNumber(u.output),
                  sub: u.reasoning > 0 ? "+\(groupedNumber(u.reasoning)) reasoning" : "на выходе"),
        ]
        if u.cacheRead > 0 {
            rows.append(.init(label: "Прочитано из кэша", value: groupedNumber(u.cacheRead), sub: "бесплатно"))
        }
        if u.cacheCreate > 0 {
            rows.append(.init(label: "Записано в кэш", value: groupedNumber(u.cacheCreate), sub: "5 мин"))
        }
        let ctxIn = u.input + u.cacheRead + u.cacheCreate
        rows.append(.init(label: "Контекст запроса", value: groupedNumber(ctxIn), sub: "всего на входе"))
        return rows
    }

    static func tokenBadge(_ u: TraceEvent.TokenUsage) -> String {
        var parts = ["↑ \(groupedNumber(u.input))", "↓ \(groupedNumber(u.output))"]
        if u.cacheRead > 0 { parts.append("⚡ \(groupedNumber(u.cacheRead)) из кэша") }
        return parts.joined(separator: "    ")
    }

    /// Fraction of the request context that came free from cache (0…1).
    static func cacheFraction(_ u: TraceEvent.TokenUsage) -> Double {
        let ctxIn = u.input + u.cacheRead + u.cacheCreate
        guard ctxIn > 0 else { return 0 }
        return Double(u.cacheRead) / Double(ctxIn)
    }

    static func cacheNote(_ u: TraceEvent.TokenUsage) -> String? {
        guard u.cacheRead > 0 else { return nil }
        let pct = cacheFraction(u) * 100
        return String(format: "%.1f%% контекста прочитано из кэша — почти без затрат", pct)
    }
}
