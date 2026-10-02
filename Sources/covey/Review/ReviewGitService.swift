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
