import Foundation
import CoveyGit

enum ReviewSide: String, Codable, Hashable {
    case new, old
}

/// The line a comment or issue points at. `lineText` is what re-anchoring
/// matches after the code moves.
struct LineAnchor: Codable, Hashable {
    var path: String
    var side: ReviewSide
    var line: Int
    var lineText: String
}

enum AnchorState: String, Codable, Hashable {
    /// The line still says what it said.
    case current
    /// Moved to a unique new position; `note` says from where.
    case tracked
    /// The text is gone or ambiguous; listed above the diff, not inline.
    case outdated
    /// The file dropped out of the comparison.
    case fileGone
}

enum IssueSeverity: String, Codable, CaseIterable, Hashable {
    case high = "High", medium = "Medium", low = "Low"
}

enum IssueStatus: String, Codable, CaseIterable, Hashable {
    case open = "Open", inProgress = "In Progress", resolved = "Resolved", dismissed = "Dismissed"

    /// Open or being worked on — counts toward a file's `!`.
    var isActive: Bool { self == .open || self == .inProgress }
}

struct ReviewComment: Codable, Hashable, Identifiable {
    let id: UUID
    var anchor: LineAnchor
    var text: String
    var createdAt: Date
    var sentTo: String?
    var sentAt: Date?
    var anchorState: AnchorState = .current
    var note: String?
}

struct ReviewIssue: Codable, Hashable, Identifiable {
    let id: Int
    var anchor: LineAnchor
    var title: String
    var body: String
    var severity: IssueSeverity
    var status: IssueStatus
    var createdAt: Date
    var sentTo: String?
    var sentAt: Date?
    var anchorState: AnchorState = .current
    var note: String?
}

enum FileReviewState: String, Codable, Hashable {
    case unread, reviewing, reviewed
}

struct FileReview: Codable, Hashable {
    var state: FileReviewState = .unread
    /// Hash of the diff the reviewer saw when marking the file reviewed.
    var reviewedDiffHash: String?
    /// The diff changed after it was marked reviewed.
    var changedSinceReviewed = false
}

/// Everything one review remembers, keyed by (worktree, comparison).
struct ReviewRecord: Codable, Equatable {
    var version = 1
    var worktree: String
    var comparison: GitComparison
    var files: [String: FileReview] = [:]
    var comments: [ReviewComment] = []
    var issues: [ReviewIssue] = []
    var nextIssueId = 1
    var targetSession: String?
}

enum IssueTitle {
    static let limit = 60

    /// The first non-empty line, trimmed, at most `limit` characters.
    static func make(from text: String) -> String {
        let first = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }
}
