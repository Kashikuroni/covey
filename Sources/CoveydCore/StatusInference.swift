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
        let start = max(0, lines.count - 20)
        var opts: [String] = []
        var expect = 1
        for line in lines[start...] {
            var t = Substring(line)
            while let f = t.first, f.isWhitespace || "❯>●·".contains(f) {
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
