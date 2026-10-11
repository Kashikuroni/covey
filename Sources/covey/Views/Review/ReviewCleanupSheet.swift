import SwiftUI

/// Batch cleanup confirmation: pre-ticked safe candidates, sequential
/// removal, per-row failures stay visible (donor cleanup window).
struct ReviewCleanupSheet: View {
    @Bindable var repo: ReviewRepoModel
    let tk: Tokens

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("CLEAN UP FINISHED WORKTREES").font(ReviewFont.caption()).foregroundStyle(tk.t3)
                ForEach(repo.cleanupRows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(get: { row.ticked },
                                             set: { repo.tickCleanup(row.id, $0) })) {
                            HStack(spacing: 6) {
                                Text((row.path as NSString).lastPathComponent)
                                    .font(ReviewFont.mono(12)).foregroundStyle(tk.t1)
                                if row.canDeleteBranch {
                                    Toggle(isOn: Binding(get: { row.removeBranch },
                                                         set: { repo.tickCleanupBranch(row.id, $0) })) {
                                        Text("and branch").font(.system(size: 11)).foregroundStyle(tk.t3)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        if let error = row.error {
                            Text(error).font(.system(size: 11)).foregroundStyle(tk.err)
                        }
                    }
                }
                HStack {
                    Spacer()
                    ReviewButton(title: "Cancel", tk: tk) { repo.cleanupSheetOpen = false }
                    let counts = repo.pendingCleanupCounts()
                    let failed = repo.cleanupRows.filter { $0.error != nil && !$0.done }.count
                    ReviewButton(title: repo.cleanupRunning
                                 ? "Removing…"
                                 : cleanupButtonLabel(failed: failed,
                                                      worktrees: counts.worktrees,
                                                      branches: counts.branches),
                                 prominent: true, tk: tk) {
                        Task { await repo.runCleanup() }
                    }
                    .disabled(repo.cleanupRunning || counts.worktrees == 0)
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(tk.surf3)
            .overlay(RoundedRectangle(cornerRadius: Tokens.r).stroke(tk.bd3))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 60)
        }
    }
}
