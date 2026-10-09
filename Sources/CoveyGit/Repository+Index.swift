import Foundation

/// One path's index state from porcelain v2: the review sidebar's staged chip.
public struct IndexEntry: Equatable, Sendable {
    public var path: String
    public var staged: Bool
    public var isUntracked: Bool

    public init(path: String, staged: Bool, isUntracked: Bool) {
        self.path = path
        self.staged = staged
        self.isUntracked = isUntracked
    }
}

extension Repository {
    /// Per-path staged/untracked state (`git status --porcelain=v2 -z`).
    /// Cheap: the same call the fingerprint already makes.
    public func indexStatus() throws -> [IndexEntry] {
        let output = try git(["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                             readOnly: true)
        return Porcelain.parse(output).map { entry in
            // v2 marks "unmodified" with '.', not a space (v1 convention).
            IndexEntry(path: entry.path,
                       staged: !entry.isUntracked && entry.x != ".",
                       isUntracked: entry.isUntracked)
        }
    }

    /// Stages paths or directories; `add -A` so deletions stage too.
    public func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try git(["add", "-A", "--"] + paths)
    }

    public func stageAll() throws {
        try git(["add", "-A"])
    }

    /// Unstages paths — index only, the working tree is untouched.
    public func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try git(["reset", "--"] + paths)
    }

    /// Unstages everything; refuses on an unborn branch (no HEAD yet).
    public func unstageAll() throws {
        try git(["reset"])
    }
}
