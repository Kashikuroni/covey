import Foundation
import CoveyGit
import CoveyKit

/// The management popover's state: project worktrees with donor states,
/// the current worktree's branches, and PRs. Ops-layer member #2 (umbrella
/// invariant 1): every write goes through ReviewGitReading → CoveyGit.
@MainActor
@Observable
final class ReviewRepoModel {
    let projectRoot: String
    var currentWorktree: String
    var popoverOpen = false

    var worktreeRows: [WorktreeRow] = []
    var branchRows: [BranchRow] = []
    var base = ""
    var prs: [ReviewPR] = []
    var prError: String?
    var rowErrors: [String: String] = [:]
    var cleanupSheetOpen = false
    var cleanupRows: [CleanupCandidate] = []
    var cleanupRunning = false
    var loading = false

    @ObservationIgnored let git: ReviewGitReading
    @ObservationIgnored let prReader: ReviewPRReading
    @ObservationIgnored let liveSessions: () -> [(dir: String, agent: String)]

    init(projectRoot: String, currentWorktree: String,
         git: ReviewGitReading, prReader: ReviewPRReading,
         liveSessions: @escaping () -> [(dir: String, agent: String)]) {
        self.projectRoot = projectRoot
        self.currentWorktree = currentWorktree
        self.git = git
        self.prReader = prReader
        self.liveSessions = liveSessions
    }

    private var protectedList: [String] {
        protectedBranches + [base]
    }

    /// git reports worktree paths through resolved symlinks; session dirs come
    /// from the daemon — both sides canonicalized before comparing.
    private func canon(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func isLive(_ path: String) -> String? {
        let sessions = liveSessions().map { (dir: canon($0.dir), agent: $0.agent) }
        return isLiveSession(canon(path), sessions: sessions)
    }

    func reload() async {
        loading = true
        defer { loading = false }
        guard let entries = try? await git.worktreeList(root: projectRoot) else { return }
        base = await git.defaultBase(worktree: currentWorktree) ?? "main"
        let merged = (try? await git.mergedBranches(root: projectRoot, into: base)) ?? []
        let prSnapshot = await prReader.load(root: projectRoot)
        prs = prSnapshot.prs
        prError = prSnapshot.error
        let now = Int64(Date().timeIntervalSince1970)

        var rows: [WorktreeRow] = []
        for entry in entries {
            let summary = await git.summary(worktree: entry.path)
            let clean = summary.map { $0.unstaged.files == 0 && $0.staged.files == 0
                                      && $0.untracked == 0 } ?? false
            var ahead = 0
            if let branch = entry.branch {
                ahead = (await git.aheadBehind(root: projectRoot, branch: branch,
                                               base: base)).ahead
            }
            let last = await git.lastCommit(worktree: entry.path)
            let agent = isLive(entry.path)
            let mergedInto = entry.branch.map { merged.contains($0) } ?? false
            let state = reviewWorktreeState(
                isPrimary: entry.isPrimary, hasLiveSession: agent != nil,
                branchIsBase: entry.branch == base, clean: clean,
                mergedIntoBase: mergedInto, ahead: ahead,
                lastCommit: last, now: now)
            rows.append(WorktreeRow(path: entry.path, branch: entry.branch,
                                    isPrimary: entry.isPrimary, state: state,
                                    agent: agent, clean: clean, mergedIntoBase: mergedInto,
                                    ahead: ahead, lastCommit: last,
                                    isCurrent: canon(entry.path) == canon(currentWorktree)))
        }
        worktreeRows = rows

        let names = await git.localBranches(worktree: currentWorktree)
        var branches: [BranchRow] = []
        for name in names {
            let counts = await git.aheadBehind(root: projectRoot, branch: name, base: base)
            branches.append(BranchRow(
                name: name, isCurrentBranch: name == currentBranchName(),
                ahead: counts.ahead, behind: counts.behind,
                mergedIntoBase: merged.contains(name),
                isProtected: protectedList.contains(name),
                checkedOutAt: worktreeRows.first { $0.branch == name }?.path))
        }
        branchRows = branches
    }

    /// One forced gh call; the popover's Refresh button.
    func refreshPRs() async {
        let snapshot = await prReader.refresh(root: projectRoot)
        prs = snapshot.prs
        prError = snapshot.error
    }

    private func currentBranchName() -> String? {
        worktreeRows.first { $0.isCurrent }?.branch
    }

    private func noteRowError(_ key: String, _ error: Error) {
        let text = String(describing: error)
        rowErrors[key] = text
        EventLog.note("error", text)
    }

    // MARK: Row actions

    /// Removes a worktree. CoveyGit's removal is `--force`, so git never
    /// refuses — a dirty tree needs the explicit `confirmed` second step
    /// (review fix I1: uncommitted changes must not vanish on one click).
    func removeWorktree(_ path: String, deleteBranchToo: Bool, confirmed: Bool = false) async {
        if let row = worktreeRows.first(where: { $0.path == path }), !row.clean, !confirmed {
            rowErrors[path] = "has uncommitted changes — confirm the removal"
            return
        }
        do {
            try await git.removeWorktree(path: path)
            rowErrors[path] = nil
            if deleteBranchToo,
               let row = worktreeRows.first(where: { $0.path == path }),
               let branch = row.branch, !protectedList.contains(branch) {
                try? await git.deleteBranch(worktree: currentWorktree, branch: branch,
                                            protected: protectedList)
            }
        } catch {
            noteRowError(path, error)
        }
        await reload()
    }

    func promote(_ path: String) async {
        guard let branch = worktreeRows.first(where: { $0.path == path })?.branch else { return }
        do {
            try await git.promoteWorktree(root: projectRoot, path: path, branch: branch)
            rowErrors[path] = nil
        } catch {
            noteRowError(path, error)
        }
        await reload()
    }

    func checkout(_ branch: String, in path: String) async {
        if isLive(path) != nil {
            rowErrors[path] = "a live agent session is working here — checkout is disabled"
            return
        }
        do {
            try await git.checkout(worktree: path, branch: branch)
            rowErrors[path] = nil
        } catch {
            noteRowError(path, error)
        }
        await reload()
    }

    func deleteBranch(_ name: String) async {
        do {
            try await git.deleteBranch(worktree: currentWorktree, branch: name,
                                       protected: protectedList)
            rowErrors[name] = nil
        } catch {
            noteRowError(name, error)
        }
        await reload()
    }

    var canUpdateFromBase: Bool {
        currentBranchName() != nil && isLive(currentWorktree) == nil
    }

    func updateFromBase() async {
        guard canUpdateFromBase else {
            rowErrors[currentWorktree] = "a live agent session is working here — update is disabled"
            return
        }
        do {
            try await git.updateFromBase(worktree: currentWorktree, base: base)
            rowErrors[currentWorktree] = nil
        } catch {
            noteRowError(currentWorktree, error)
        }
        await reload()
    }

    /// Git-level worktree creation; returns git's refusal text, nil on success.
    func newWorktree(name: String, base: String?) async -> String? {
        let worktrees = (projectRoot as NSString).appendingPathComponent(".worktrees")
        let path = (worktrees as NSString).appendingPathComponent(name)
        do {
            try await git.addWorktree(root: projectRoot, path: path,
                                      newBranch: name, base: base ?? self.base)
            await reload()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: Batch cleanup

    /// Popover-footer counts: what WOULD be cleaned now, derived straight from
    /// the worktree rows — not from the sheet state (review fix C2: the sheet
    /// rows are empty until the button is pressed, so counting them disabled
    /// the button forever).
    func cleanupAvailabilityCounts() -> (worktrees: Int, branches: Int) {
        let candidates = cleanupCandidates(worktreeRows)
        return (candidates.count, candidates.filter(\.canDeleteBranch).count)
    }

    /// Esc on the cleanup sheet: closes it and reports whether it was open.
    func escapeCleanupSheet() -> Bool {
        guard cleanupSheetOpen else { return false }
        cleanupSheetOpen = false
        return true
    }

    func openCleanupSheet() {
        cleanupRows = cleanupCandidates(worktreeRows)
        cleanupSheetOpen = true
    }

    func tickCleanup(_ id: String, _ value: Bool) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == id }) else { return }
        cleanupRows[index].ticked = value
    }

    func tickCleanupBranch(_ id: String, _ value: Bool) {
        guard let index = cleanupRows.firstIndex(where: { $0.id == id }) else { return }
        cleanupRows[index].removeBranch = value
    }

    func pendingCleanupCounts() -> (worktrees: Int, branches: Int) {
        let pending = cleanupRows.filter { $0.ticked && !$0.done }
        let branches = pending.filter { $0.removeBranch && $0.canDeleteBranch }.count
        return (pending.count, branches)
    }

    func runCleanup() async {
        cleanupRunning = true
        defer { cleanupRunning = false }
        for index in cleanupRows.indices where cleanupRows[index].ticked && !cleanupRows[index].done {
            do {
                try await git.removeWorktree(path: cleanupRows[index].path)
                if cleanupRows[index].removeBranch, let branch = cleanupRows[index].branch,
                   cleanupRows[index].canDeleteBranch {
                    try? await git.deleteBranch(worktree: currentWorktree, branch: branch,
                                                protected: protectedList)
                }
                cleanupRows[index].error = nil
                cleanupRows[index].done = true
                EventLog.note("cleanup", "removed \(cleanupRows[index].path)")
            } catch {
                cleanupRows[index].error = String(describing: error)
            }
        }
        await reload()
        if !cleanupRows.contains(where: { $0.ticked && !$0.done && $0.error != nil }) {
            cleanupSheetOpen = false
        }
    }
}
