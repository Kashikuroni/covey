import Foundation
import CoveyKit

struct SessionGitDelta: Equatable {
    let added: UInt32
    let removed: UInt32
}

func sessionGitDelta(_ git: GitInfo) -> SessionGitDelta? {
    guard git.added > 0 || git.removed > 0 else { return nil }
    return SessionGitDelta(added: git.added, removed: git.removed)
}

func branchDeleteDestinations(
    deleting: String,
    repoRoot: String,
    branches: [String],
    worktrees: [String: String]
) -> [String] {
    let root = URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path
    return branches.filter { branch in
        guard branch != deleting else { return false }
        guard let path = worktrees[branch] else { return true }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == root
    }
}

func preferredBranchDeleteDestination(_ branches: [String]) -> String? {
    for preferred in protectedBranches where branches.contains(preferred) {
        return preferred
    }
    return branches.first
}

func worktreeBranchDeletionBlockReason(
    branch: String?, dirty: Bool, merged: Bool
) -> String? {
    guard let branch else { return "Branch status unavailable" }
    if protectedBranches.contains(branch) { return "Branch is protected" }
    if dirty { return "Uncommitted changes" }
    _ = merged
    return nil
}
