import CoveyGit

enum ReviewWorktreeState: Equatable {
    case root, active, idle, stale, done
}

/// One row of the management popover's worktree zone.
struct WorktreeRow: Equatable, Identifiable {
    let path: String
    let branch: String?          // nil = detached
    let isPrimary: Bool
    let state: ReviewWorktreeState
    let agent: String?           // live session agent for .active
    let clean: Bool
    let mergedIntoBase: Bool
    let ahead: Int
    let lastCommit: Int64?
    let isCurrent: Bool          // the worktree under review

    var id: String { path }
}

/// Donor order semantics (feat/git-window's WorktreeActivity), order matters:
/// Root → Active(live session) → Idle(=base) → Done(merged+clean+0 ahead) →
/// Stale(>14 days) → Idle. Merged+dirty lands on Idle (never suggest deleting
/// unsaved work); old+ahead lands on Stale (age beats the idle fallback).
func reviewWorktreeState(isPrimary: Bool, hasLiveSession: Bool, branchIsBase: Bool,
                         clean: Bool, mergedIntoBase: Bool, ahead: Int,
                         lastCommit: Int64?, now: Int64,
                         staleAfterSeconds: Int64 = 14 * 24 * 3600) -> ReviewWorktreeState {
    if isPrimary { return .root }
    if hasLiveSession { return .active }
    if branchIsBase { return .idle }
    if mergedIntoBase && clean && ahead == 0 { return .done }
    if let lastCommit, now - lastCommit > staleAfterSeconds { return .stale }
    return .idle
}

/// One row of the popover's branches zone.
struct BranchRow: Equatable, Identifiable {
    let name: String
    let isCurrentBranch: Bool
    let ahead: Int
    let behind: Int
    let mergedIntoBase: Bool
    let isProtected: Bool
    let checkedOutAt: String?    // worktree path holding this branch

    var id: String { name }
}

/// One row of the cleanup confirmation sheet. Safe rows start ticked.
struct CleanupCandidate: Equatable, Identifiable {
    let path: String
    let branch: String?
    let canDeleteBranch: Bool
    var ticked = true
    var removeBranch = true
    var error: String?
    var done = false

    var id: String { path }
}

/// Donor candidate filter: safe (Done) and not the repository root.
func cleanupCandidates(_ rows: [WorktreeRow]) -> [CleanupCandidate] {
    rows.filter { !$0.isPrimary && $0.state == .done }
        .map { row in
            CleanupCandidate(path: row.path, branch: row.branch,
                             canDeleteBranch: row.branch != nil)
        }
}

func cleanupConfirmLabel(worktrees: Int, branches: Int) -> String {
    guard worktrees > 0 || branches > 0 else { return "Remove nothing" }
    let wt = worktrees == 1 ? "1 worktree" : "\(worktrees) worktrees"
    guard branches > 0 else { return "Remove \(wt)" }
    let br = branches == 1 ? "1 branch" : "\(branches) branches"
    return "Remove \(wt) and \(br)"
}

/// The live session working in `worktreePath` (exact dir or inside it), if any.
func isLiveSession(_ worktreePath: String,
                   sessions: [(dir: String, agent: String)]) -> String? {
    sessions.first { $0.dir == worktreePath || $0.dir.hasPrefix(worktreePath + "/") }?.agent
}
