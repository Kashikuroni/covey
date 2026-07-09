import CoveyKit

/// Pure agent-status inference, a port of amux-core's `status.rs`.
/// Input is the rendered visible-screen text (from `ScreenModel`), so unlike
/// the Rust original no ANSI stripping is needed. No IO.
public enum StatusInference {
    /// Substrings that mark an agent as actively working. Claude Code renders
    /// "esc to interrupt" while busy and drops it when idle.
    static let workingMarkers = ["esc to interrupt"]

    /// Detects a bottom-anchored numbered menu (Claude Code permission/choice
    /// prompt). Returns option labels for digits 1..N, or empty if no
    /// consecutive `1.` `2.` … run of at least two is found in the last 20 lines.
    public static func parsePrompt(_ screen: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        let start = max(0, lines.count - 24)
        var opts: [String] = []
        var expect = 1
        for line in lines[start...] {
            var t = Substring(line)
            // Strip any leading decoration before the digit: whitespace, the
            // selection cursor and bullets (glyphs vary across Claude builds:
            // ❯ ▶ ► ➤ • · ● …), box borders, and generic symbol/punctuation.
            while let f = t.first,
                  f.isWhitespace || f.isSymbol || f.isPunctuation
                  || "❯▶►➤‣•·●○◦│".contains(f) {
                t = t.dropFirst()
            }
            let prefix = "\(expect)."
            guard t.hasPrefix(prefix) else { continue }
            let label = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                opts.append(String(label.prefix(40)))
                expect += 1
            }
        }
        return opts.count >= 2 ? opts : []
    }

    /// Footer markers Claude Code prints under an AskUserQuestion selection box.
    /// A robust, format-independent signal that the agent is waiting for a
    /// choice even when `parsePrompt` cannot line up the options.
    static let promptMarkers = ["to navigate", "Esc to cancel"]

    /// Whether the screen shows a pending selection prompt (options parsed OR a
    /// footer marker present). Drives the `.waiting` status.
    public static func hasSelectionPrompt(_ screen: String) -> Bool {
        if !parsePrompt(screen).isEmpty { return true }
        return promptMarkers.contains { screen.contains($0) }
    }

    /// Hash of screen content for in-process change detection between ticks.
    /// Values are not stable across process restarts (like Rust's DefaultHasher).
    public static func contentHash(_ s: String) -> Int {
        var h = Hasher()
        h.combine(s)
        return h.finalize()
    }

    /// Whether the screen shows an agent actively working.
    public static func isWorking(_ screen: String) -> Bool {
        workingMarkers.contains { screen.contains($0) }
    }

    /// First observation (no previous hash) is `.idle`; a changed hash → `.running`.
    public static func computeStatus(prev: Int?, current: Int) -> Status {
        if let prev, prev != current { return .running }
        return .idle
    }

    /// Derive a session's status. Precedence: pending prompt → `.waiting`;
    /// working marker → `.running`; otherwise frame-diff via `computeStatus`.
    public static func deriveStatus(
        content: String, prevHash: Int?, currentHash: Int, hasPrompt: Bool
    ) -> Status {
        if hasPrompt { return .waiting }
        if isWorking(content) { return .running }
        return computeStatus(prev: prevHash, current: currentHash)
    }
}
