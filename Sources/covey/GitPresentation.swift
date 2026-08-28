import Foundation
import CoveyKit

struct SessionGitDelta: Equatable {
    let marker: String
    let added: UInt32
    let removed: UInt32
}

func sessionGitDelta(_ git: GitInfo) -> SessionGitDelta? {
    if git.unstaged.files > 0 {
        return SessionGitDelta(
            marker: "U", added: git.unstaged.added, removed: git.unstaged.removed
        )
    }
    if git.staged.files > 0 {
        return SessionGitDelta(
            marker: "S", added: git.staged.added, removed: git.staged.removed
        )
    }
    return nil
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
