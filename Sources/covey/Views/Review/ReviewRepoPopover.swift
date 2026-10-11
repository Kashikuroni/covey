import SwiftUI
import AppKit
import CoveyKit
import CoveyGit

/// The management popover: worktrees with states, the current repository's
/// branches, PR badges. Mouse-first, like ComparisonEditor.
struct ReviewRepoPopover: View {
    @Bindable var repo: ReviewRepoModel
    let app: AppModel
    let tk: Tokens

    @State private var newWorktreePrompt = false
    @State private var pendingRemove: String?
    @State private var newWorktreeName = ""
    @State private var newWorktreeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("WORKTREES") {
                ForEach(repo.worktreeRows) { row in
                    worktreeRow(row)
                }
            }
            section("BRANCHES") {
                ForEach(repo.branchRows) { row in
                    branchRow(row)
                }
            }
            HStack(spacing: 8) {
                ReviewButton(title: "New worktree", tk: tk) {
                    newWorktreeError = nil
                    newWorktreePrompt = true
                }
                let counts = repo.cleanupAvailabilityCounts()
                ReviewButton(title: cleanupConfirmLabel(worktrees: counts.worktrees,
                                                        branches: counts.branches),
                             prominent: counts.worktrees > 0, tk: tk) {
                    repo.openCleanupSheet()
                }
                .disabled(counts.worktrees == 0)
                Spacer()
                ReviewButton(title: "Refresh", tk: tk) {
                    Task {
                        await repo.reload()
                        await repo.refreshPRs()
                    }
                }
            }
            if let error = repo.listError {
                Text(error).font(.system(size: 11)).foregroundStyle(tk.err)
            }
            if let error = repo.prError {
                Text(error).font(.system(size: 11)).foregroundStyle(tk.t3)
            }
        }
        .padding(14)
        .frame(width: 420)
        .onAppear { Task { await repo.reload() } }
        .sheet(isPresented: $newWorktreePrompt) { newWorktreeSheet }
    }

    // MARK: rows

    private func worktreeRow(_ row: WorktreeRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(stateColor(row.state)).frame(width: 6, height: 6)
                Text((row.path as NSString).lastPathComponent)
                    .font(ReviewFont.mono(12)).foregroundStyle(tk.t1).lineLimit(1)
                if row.isCurrent {
                    Text("reviewing").font(.system(size: 10)).foregroundStyle(tk.t3)
                }
                if let agent = row.agent {
                    Text("agent: \(agent)").font(.system(size: 10)).foregroundStyle(tk.run)
                }
                Spacer()
                if let branch = row.branch, let pr = livePR(forBranch: branch, in: repo.prs) {
                    prBadge(pr)
                }
            }
            HStack(spacing: 8) {
                Text(row.state == .root ? "root" : (row.branch ?? "detached"))
                    .font(.system(size: 10.5)).foregroundStyle(tk.t3)
                if !row.clean {
                    Text("dirty").font(.system(size: 10)).foregroundStyle(tk.warn)
                }
                if row.state == .stale, let last = row.lastCommit {
                    let days = Int((Double(Int64(Date().timeIntervalSince1970) - last)) / 86400)
                    Text("\(days)d").font(.system(size: 10)).foregroundStyle(tk.t3)
                }
                if row.state != .root, !row.isCurrent {
                    if pendingRemove == row.path {
                        popoverAction("Confirm remove") {
                            pendingRemove = nil
                            Task {
                                await repo.removeWorktree(row.path,
                                                          deleteBranchToo: row.mergedIntoBase,
                                                          confirmed: true)
                            }
                        }
                    } else {
                        popoverAction(row.clean ? "Remove" : "Remove (dirty)") {
                            pendingRemove = row.path
                        }
                    }
                    popoverAction("Promote") {
                        Task { await repo.promote(row.path) }
                    }
                    otherBranchMenu(for: row)
                }
            }
            if let error = repo.rowErrors[row.path] {
                Text(error).font(.system(size: 10)).foregroundStyle(tk.err)
            }
        }
        .padding(.vertical, 1)
    }

    /// Checkout menu: the repository's other branches, applied to this row's
    /// worktree — unavailable while a live session works there (phase-1 rule).
    private func otherBranchMenu(for row: WorktreeRow) -> some View {
        let others = repo.branchRows.map(\.name).filter { $0 != row.branch }
        return Menu {
            ForEach(others, id: \.self) { name in
                Button(name) { Task { await repo.checkout(name, in: row.path) } }
            }
        } label: {
            Text("Checkout").font(.system(size: 10.5)).foregroundStyle(tk.t2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(row.agent != nil)
        .help(row.agent != nil ? "A live agent session is working here"
                               : "Switch this worktree's branch")
    }

    private func branchRow(_ row: BranchRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.name).font(ReviewFont.mono(12))
                    .foregroundStyle(row.isCurrentBranch ? tk.t1 : tk.t2).lineLimit(1)
                if row.ahead > 0 {
                    Text("↑\(row.ahead)").font(ReviewFont.mono(10)).foregroundStyle(tk.t3)
                }
                if row.behind > 0 {
                    Text("↓\(row.behind)").font(ReviewFont.mono(10)).foregroundStyle(tk.t3)
                }
                if row.isProtected {
                    Text("protected").font(.system(size: 10)).foregroundStyle(tk.t3)
                }
                Spacer()
                if let pr = livePR(forBranch: row.name, in: repo.prs) {
                    prBadge(pr)
                }
                if !row.isCurrentBranch, !row.isProtected {
                    popoverAction("Delete") { Task { await repo.deleteBranch(row.name) } }
                }
            }
            if row.isCurrentBranch {
                HStack(spacing: 8) {
                    if repo.canUpdateFromBase {
                        popoverAction("Update from base") { Task { await repo.updateFromBase() } }
                    } else {
                        Text("update disabled — live agent")
                            .font(.system(size: 10)).foregroundStyle(tk.t3)
                    }
                }
            }
            if let error = repo.rowErrors[row.name] {
                Text(error).font(.system(size: 10)).foregroundStyle(tk.err)
            }
        }
        .padding(.vertical, 1)
    }

    private func prBadge(_ pr: ReviewPR) -> some View {
        Text("#\(pr.number) \(pr.state.lowercased())")
            .font(.system(size: 10)).foregroundStyle(tk.warn)
            .onTapGesture { openInBrowser(pr.url) }
    }

    // MARK: new worktree

    private var newWorktreeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEW WORKTREE").font(ReviewFont.caption()).foregroundStyle(tk.t3)
            TextField("branch name", text: $newWorktreeName)
                .textFieldStyle(.roundedBorder)
            if let error = newWorktreeError {
                Text(error).font(.system(size: 12)).foregroundStyle(tk.err)
            }
            HStack {
                Spacer()
                ReviewButton(title: "Cancel", tk: tk) { newWorktreePrompt = false }
                ReviewButton(title: "Create", prominent: true, tk: tk) {
                    Task {
                        if let error = await repo.newWorktree(name: newWorktreeName, base: nil) {
                            newWorktreeError = error
                        } else {
                            newWorktreePrompt = false
                            app.newSessionForWorktree(
                                dir: repo.worktreePath(
                                    named: newWorktreeName.trimmingCharacters(in: .whitespaces)))
                        }
                    }
                }
                .disabled(newWorktreeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 360)
    }

    // MARK: shared bits

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(ReviewFont.caption()).foregroundStyle(tk.t3)
            content()
        }
    }

    private func popoverAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action() }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(tk.t2)
    }

    private func stateColor(_ state: ReviewWorktreeState) -> Color {
        switch state {
        case .root: return tk.t3
        case .active: return tk.run
        case .idle: return tk.t1
        case .stale: return tk.t3
        case .done: return tk.ok
        }
    }

    private func openInBrowser(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
