import Foundation

struct ReviewPromptContext: Equatable {
    let branch: String
    /// `GitComparison.label`, e.g. "main…working tree".
    let comparison: String
    /// Absolute worktree path; prompt paths are relative to it.
    let worktree: String
}

enum ReviewPrompt {
    static func build(context: ReviewPromptContext, issues: [ReviewIssue],
                      comments: [ReviewComment]) -> String {
        var out = "Code review of \(context.branch) (\(context.comparison)) in \(context.worktree).\n"
        out += "Address the review below; leave unrelated code alone. "
            + "When done, reply with what you changed per issue number.\n"
        if !issues.isEmpty {
            out += "\n## Issues\n"
            for (n, issue) in issues.enumerated() {
                out += "\(n + 1). #\(issue.id) · \(issue.severity.rawValue) — \(issue.title)\n"
                out += "   \(location(issue.anchor))\n"
                out += "   > \(issue.anchor.lineText.trimmingCharacters(in: .whitespaces))\n"
                for line in detail(of: issue) { out += "   \(line)\n" }
            }
        }
        if !comments.isEmpty {
            out += "\n## Comments\n"
            for comment in comments {
                let lines = comment.text.split(separator: "\n", omittingEmptySubsequences: false)
                out += "- \(location(comment.anchor)) — \(lines.first ?? "")\n"
                for line in lines.dropFirst() { out += "  \(line)\n" }
            }
        }
        return out
    }

    static func location(_ anchor: LineAnchor) -> String {
        anchor.side == .new
            ? "\(anchor.path):\(anchor.line)"
            : "\(anchor.path):\(anchor.line) (removed line)"
    }

    /// The body minus its first line when that line is the title, without
    /// leading/trailing blank lines.
    private static func detail(of issue: ReviewIssue) -> [String] {
        var lines = issue.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == issue.title {
            lines.removeFirst()
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines
    }
}
