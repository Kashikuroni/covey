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
