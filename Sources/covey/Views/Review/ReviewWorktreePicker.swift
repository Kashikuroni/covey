import SwiftUI
import CoveyKit

/// The worktree under review, first in the Review top bar. Picking another
/// one is ⌥⌘R for it (`AppModel.pickReviewWorktree`): its session becomes the
/// selection, and the review is the live one if it is for that worktree,
/// else a new one (the old one is flushed). The send target picker is separate.
struct ReviewWorktreePicker: View {
    let app: AppModel
    let review: ReviewModel
    let tk: Tokens
    @State private var choices: [ReviewWorktreeChoice] = []

    var body: some View {
        Menu {
            if choices.isEmpty { Text("No agent sessions in a Git worktree") }
            ForEach(choices) { choice in
                Toggle(isOn: Binding(get: { choice.worktree == review.worktree },
                                     set: { _ in pick(choice) })) {
                    Text("\(choice.title) · \(collapseHome(choice.worktree))")
                }
            }
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tk.t1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The worktree under review")
        // Sessions come and go, and move between directories.
        .task(id: app.visibleSessions.map(\.dir)) {
            let fresh = await app.reviewWorktreeChoices()
            // A newer session list restarted the task: its answer wins.
            guard !Task.isCancelled else { return }
            choices = fresh
        }
    }

    private var title: String {
        let project = projectDefaultName(review.projectRoot)
        let leaf = (review.worktree as NSString).lastPathComponent
        return leaf == project ? project : "\(project) · \(leaf)"
    }

    private func pick(_ choice: ReviewWorktreeChoice) {
        guard choice.worktree != review.worktree else { return }
        Task { await app.pickReviewWorktree(choice) }
    }
}
