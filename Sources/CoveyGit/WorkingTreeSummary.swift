import Foundation

/// Files and line counts of one side of `git diff --numstat`.
public struct DiffTotals: Equatable, Sendable {
    public var files: UInt32
    public var added: UInt32
    public var removed: UInt32

    public init(files: UInt32, added: UInt32, removed: UInt32) {
        self.files = files
        self.added = added
        self.removed = removed
    }

    public static let empty = DiffTotals(files: 0, added: 0, removed: 0)
}

/// Branch plus independent unstaged, staged and untracked state.
public struct WorkingTreeSummary: Equatable, Sendable {
    public var branch: String
    public var unstaged: DiffTotals
    public var staged: DiffTotals
    public var untracked: UInt32

    public init(branch: String, unstaged: DiffTotals, staged: DiffTotals, untracked: UInt32) {
        self.branch = branch
        self.unstaged = unstaged
        self.staged = staged
        self.untracked = untracked
    }
}
