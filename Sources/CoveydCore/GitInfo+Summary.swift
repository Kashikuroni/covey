import CoveyGit
import CoveyKit

extension GitInfo {
    /// The wire form of a CoveyGit working-tree summary.
    public init(summary: WorkingTreeSummary) {
        func wire(_ t: DiffTotals) -> GitDiffSummary {
            GitDiffSummary(files: t.files, added: t.added, removed: t.removed)
        }
        self.init(branch: summary.branch, unstaged: wire(summary.unstaged),
                  staged: wire(summary.staged), untracked: summary.untracked)
    }
}
