import Foundation

/// A single parsed line of a note. Pure port of amux-core note.rs — only the
/// subset rendered specially is distinguished; everything else is `.text`.
enum NoteLine: Equatable {
    case task(done: Bool, text: String)
    case heading(level: Int, text: String)
    case bullet(String)
    case text(String)
    case blank
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

/// Parse a whole note buffer into typed lines (split on "\n").
func parseNote(_ buf: String) -> [NoteLine] {
    buf.components(separatedBy: "\n").map(parseLine)
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
    if trimmed.hasPrefix("- ") { return .bullet(String(trimmed.dropFirst(2))) }
    if trimmed.hasPrefix("* ") { return .bullet(String(trimmed.dropFirst(2))) }
    return .text(line)
}

/// `(done, total)` task counts for the card progress indicator.
func taskCounts(_ buf: String) -> (done: Int, total: Int) {
    var done = 0, total = 0
    for line in buf.components(separatedBy: "\n") {
        if let t = parseTask(line) {
            total += 1
            if t.done { done += 1 }
        }
    }
    return (done, total)
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
