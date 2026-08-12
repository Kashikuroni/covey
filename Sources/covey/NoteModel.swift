import Foundation

/// A single parsed markdown line. Only the subset rendered specially is
/// distinguished; everything else is `.text`.
enum NoteLine: Equatable {
    case task(done: Bool, text: String)
    case heading(level: Int, text: String)
    case bullet(String)
    case text(String)
    case blank
    case rule                 // --- / *** / ___ divider
    case quote(String)        // "> " blockquote, marker stripped
    case codeFence            // ``` delimiter line
    case code(String)         // raw line inside a fence
}

/// If `line` is a checkbox task, returns `(done, text)` with the `- [ ] `
/// prefix stripped; leading whitespace allowed. Strict: only `- [ ]`/`- [x]`
/// (or `X`) qualify, so body text mentioning "[ ]" never false-matches.
func parseTask(_ line: String) -> (done: Bool, text: String)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.hasPrefix("- [") else { return nil }
    let chars = Array(trimmed)
    guard chars.count >= 5, chars[4] == "]" else { return nil }
    let done: Bool
    switch chars[3] {
    case " ": done = false
    case "x", "X": done = true
    default: return nil
    }
    let body = String(chars.dropFirst(5)).drop(while: { $0 == " " })
    return (done, String(body))
}

/// Parse a markdown buffer into typed lines (split on "\n").
/// INVARIANT: exactly one NoteLine per input line so editor preview maps
/// buffer lines to the Vim cursor 1:1, fences included.
func parseNote(_ buf: String) -> [NoteLine] {
    var inFence = false
    return buf.components(separatedBy: "\n").map { line in
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        if trimmed.hasPrefix("```") {
            inFence.toggle()
            return .codeFence
        }
        if inFence { return .code(line) }
        return parseLine(line)
    }
}

private func parseLine(_ line: String) -> NoteLine {
    if let task = parseTask(line) { return .task(done: task.done, text: task.text) }
    let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
    if trimmed.isEmpty { return .blank }
    if trimmed.hasPrefix("#") {
        let level = min(6, trimmed.prefix(while: { $0 == "#" }).count)
        let text = String(trimmed.dropFirst(trimmed.prefix(while: { $0 == "#" }).count))
            .drop(while: { $0 == " " })
        return .heading(level: level, text: String(text))
    }
    // Rules before bullets: "---" must not read as an empty bullet, while
    // "- - -" (spaced) stays a bullet — single repeated character only.
    if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
       trimmed.allSatisfy({ $0 == first }) {
        return .rule
    }
    if trimmed.hasPrefix(">") {
        let body = trimmed.dropFirst().drop(while: { $0 == " " })
        return .quote(String(body))
    }
    if trimmed.hasPrefix("- ") { return .bullet(String(trimmed.dropFirst(2))) }
    if trimmed.hasPrefix("* ") { return .bullet(String(trimmed.dropFirst(2))) }
    return .text(line)
}

/// Buffer line indices (0-based) that are tasks, in order; the position in
/// the result is the task ordinal.
func taskLineIndices(_ buf: String) -> [Int] {
    buf.components(separatedBy: "\n").enumerated()
        .filter { parseTask($0.element) != nil }
        .map(\.offset)
}

/// Flip the checkbox of the `ordinal`-th task; out-of-range is a no-op.
/// Preserves indentation and all other text.
func toggleTask(_ buf: String, ordinal: Int) -> String {
    var seen = 0
    let lines = buf.components(separatedBy: "\n").map { line -> String in
        guard let task = parseTask(line) else { return line }
        defer { seen += 1 }
        guard seen == ordinal else { return line }
        let leadCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let lead = String(line.prefix(leadCount))
        let rest = String(line.dropFirst(leadCount))
        let mark = task.done ? " " : "x"
        return "\(lead)- [\(mark)]\(rest.dropFirst(5))"
    }
    return lines.joined(separator: "\n")
}

/// Delete the lines of the tasks whose ordinals are in `ordinals`.
func removeTasks(_ buf: String, ordinals: Set<Int>) -> String {
    var seen = 0
    let lines = buf.components(separatedBy: "\n").filter { line in
        guard parseTask(line) != nil else { return true }
        defer { seen += 1 }
        return !ordinals.contains(seen)
    }
    return lines.joined(separator: "\n")
}

/// Render the given task ordinals as "1. text\n2. text", renumbered from 1
/// in the given order; unknown ordinals skipped.
func selectedAsNumbered(_ buf: String, ordinals: [Int]) -> String {
    let texts = buf.components(separatedBy: "\n").compactMap { parseTask($0)?.text }
    var out: [String] = []
    for ord in ordinals where ord < texts.count {
        out.append("\(out.count + 1). \(texts[ord])")
    }
    return out.joined(separator: "\n")
}
