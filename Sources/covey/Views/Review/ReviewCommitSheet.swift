import SwiftUI

/// Modal card composing a commit from the staged set (pattern: ReviewSendSheet).
struct ReviewCommitSheet: View {
    @Bindable var model: ReviewModel
    let tk: Tokens
    @State private var summary = ""
    @State private var commitBody = ""

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { model.cancelCommit() }
            VStack(alignment: .leading, spacing: 14) {
                Text("COMMIT STAGED CHANGES").font(ReviewFont.caption()).foregroundStyle(tk.t3)
                Text(model.stagedPaths.count == 1 ? "1 file staged"
                     : "\(model.stagedPaths.count) files staged")
                    .font(.system(size: 12))
                    .foregroundStyle(tk.t2)
                TextField("Summary", text: $summary)
                    .textFieldStyle(.plain)
                    .font(ReviewFont.mono(12))
                    .padding(10)
                    .background(tk.surface)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd2))
                TextField("Body (optional)", text: $commitBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ReviewFont.mono(12))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(tk.surface)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd2))
                if let error = model.commitError {
                    Text(error).font(.system(size: 12)).foregroundStyle(tk.err)
                }
                HStack {
                    ReviewButton(title: "Unstage all", tk: tk) {
                        Task {
                            await model.unstageAllChanges()
                            summary = ""
                            commitBody = ""
                        }
                    }
                    Spacer()
                    ReviewButton(title: "Cancel", tk: tk) { model.cancelCommit() }
                    ReviewButton(title: commitButtonTitle(committing: model.committing),
                                 prominent: true, tk: tk) {
                        Task { await model.commit(summary: summary, body: commitBody) }
                    }
                    .disabled(!model.canCommit(summary))
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
