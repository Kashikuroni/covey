import Foundation
import CoveyGit

/// The git reads a Review window makes. Async and off the main thread;
/// `ReviewGitService` is the real one, tests script a fake.
protocol ReviewGitReading: Sendable {
    func branchLabel(worktree: String) async -> String?
    func localBranches(worktree: String) async -> [String]
    func defaultBase(worktree: String) async -> String?
    func changes(worktree: String, comparison: GitComparison) async throws -> ComparisonState
    func fingerprint(worktree: String, comparison: GitComparison, paths: [String]) async throws -> String
    func diff(worktree: String, comparison: GitComparison, mergeBase: String,
              file: ChangedFile, fullFile: Bool) async throws -> FileDiff

    // Ops surface — the only writes, all via CoveyGit (umbrella invariant 1).
    func indexStatus(worktree: String) async throws -> [IndexEntry]
    func upstreamInfo(worktree: String) async -> UpstreamInfo?
    func stage(worktree: String, paths: [String]) async throws
    func stageAll(worktree: String) async throws
    func unstage(worktree: String, paths: [String]) async throws
    func unstageAll(worktree: String) async throws
    func commit(worktree: String, summary: String, body: String, amend: Bool) async throws -> String
    func push(worktree: String, remote: String, setUpstream: Bool) async throws
    func fetch(worktree: String, remote: String) async throws

    // Management surface (phase 2) — reads repo-wide, writes via CoveyGit.
    func worktreeList(root: String) async throws -> [WorktreeListEntry]
    func mergedBranches(root: String, into base: String) async throws -> [String]
    func lastCommit(worktree: String) async -> Int64?
    func aheadBehind(root: String, branch: String, base: String) async -> (ahead: Int, behind: Int)
    func summary(worktree: String) async -> WorkingTreeSummary?
    func addWorktree(root: String, path: String, newBranch: String, base: String) async throws
    func removeWorktree(path: String) async throws
    func promoteWorktree(root: String, path: String, branch: String) async throws
    func checkout(worktree: String, branch: String) async throws
    func deleteBranch(worktree: String, branch: String, protected: [String]) async throws
    func updateFromBase(worktree: String, base: String) async throws
}

struct ReviewGitService: ReviewGitReading {
    /// Current branch, else short HEAD (detached); nil outside a repository.
    func branchLabel(worktree: String) async -> String? {
        await offMain {
            let repo = Repository(at: worktree)
            guard repo.toplevel() != nil else { return nil }
            return repo.currentBranch() ?? repo.shortHead() ?? "HEAD"
        }
    }

    func localBranches(worktree: String) async -> [String] {
        await offMain { Repository(at: worktree).localBranches() }
    }

    func defaultBase(worktree: String) async -> String? {
        await offMain { Repository(at: worktree).defaultBase() }
    }

    func changes(worktree: String, comparison: GitComparison) async throws -> ComparisonState {
        try await offMainThrowing { try Repository(at: worktree).changes(in: comparison) }
    }

    func fingerprint(worktree: String, comparison: GitComparison, paths: [String]) async throws -> String {
        try await offMainThrowing { try Repository(at: worktree).fingerprint(of: comparison, paths: paths) }
    }

    func diff(worktree: String, comparison: GitComparison, mergeBase: String,
              file: ChangedFile, fullFile: Bool) async throws -> FileDiff {
        try await offMainThrowing {
            try Repository(at: worktree).diff(of: file, in: comparison, mergeBase: mergeBase, fullFile: fullFile)
        }
    }

    func indexStatus(worktree: String) async throws -> [IndexEntry] {
        try await offMainThrowing { try Repository(at: worktree).indexStatus() }
    }

    func upstreamInfo(worktree: String) async -> UpstreamInfo? {
        await offMain { try? Repository(at: worktree).upstreamInfo() ?? nil }
    }

    func stage(worktree: String, paths: [String]) async throws {
        try await offMainThrowing { try Repository(at: worktree).stage(paths: paths) }
    }

    func stageAll(worktree: String) async throws {
        try await offMainThrowing { try Repository(at: worktree).stageAll() }
    }

    func unstage(worktree: String, paths: [String]) async throws {
        try await offMainThrowing { try Repository(at: worktree).unstage(paths: paths) }
    }

    func unstageAll(worktree: String) async throws {
        try await offMainThrowing { try Repository(at: worktree).unstageAll() }
    }

    func commit(worktree: String, summary: String, body: String, amend: Bool) async throws -> String {
        try await offMainThrowing {
            try Repository(at: worktree).commit(summary: summary, body: body, amend: amend)
        }
    }

    func push(worktree: String, remote: String, setUpstream: Bool) async throws {
        try await offMainThrowing {
            try Repository(at: worktree).push(remote: remote, setUpstream: setUpstream)
        }
    }

    func fetch(worktree: String, remote: String) async throws {
        try await offMainThrowing { try Repository(at: worktree).fetch(remote: remote) }
    }

    func worktreeList(root: String) async throws -> [WorktreeListEntry] {
        try await offMainThrowing { try Repository(at: root).listWorktrees() }
    }

    func mergedBranches(root: String, into base: String) async throws -> [String] {
        try await offMainThrowing { try Repository(at: root).mergedBranches(into: base) }
    }

    func lastCommit(worktree: String) async -> Int64? {
        await offMain { try? Repository(at: worktree).lastCommitTimestamp() ?? nil }
    }

    func aheadBehind(root: String, branch: String, base: String) async -> (ahead: Int, behind: Int) {
        await offMain { (try? Repository(at: root).aheadBehind(branch: branch, base: base)) ?? (0, 0) }
    }

    func summary(worktree: String) async -> WorkingTreeSummary? {
        await offMain { Repository(at: worktree).workingTreeSummary() }
    }

    func addWorktree(root: String, path: String, newBranch: String, base: String) async throws {
        try await offMainThrowing {
            try Repository(at: root).addWorktree(at: path, newBranch: newBranch, base: base)
        }
    }

    func removeWorktree(path: String) async throws {
        try await offMainThrowing { try Repository(at: path).removeWorktree(at: path) }
    }

    func promoteWorktree(root: String, path: String, branch: String) async throws {
        // The ROOT checkout is the receiver: the worktree is removed
        // mid-operation, so a worktree receiver could not check the branch
        // out afterwards (review fix C3).
        try await offMainThrowing {
            try Repository(at: root).promoteWorktree(at: path, branch: branch)
        }
    }

    func checkout(worktree: String, branch: String) async throws {
        try await offMainThrowing { try Repository(at: worktree).checkout(branch) }
    }

    func deleteBranch(worktree: String, branch: String, protected: [String]) async throws {
        try await offMainThrowing {
            try Repository(at: worktree).deleteBranch(branch, protected: protected)
        }
    }

    func updateFromBase(worktree: String, base: String) async throws {
        try await offMainThrowing { try Repository(at: worktree).updateFromBase(base: base) }
    }
}

/// Runs blocking work (git, disk) on a global queue: never on the main
/// thread, and never parking a thread of Swift's small cooperative pool.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
