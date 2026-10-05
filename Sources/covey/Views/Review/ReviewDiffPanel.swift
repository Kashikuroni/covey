import SwiftUI
import CoveyGit

struct ReviewDiffPanel: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        Group {
            if let path = model.selectedPath, let file = model.file(path) {
                VStack(alignment: .leading, spacing: 0) {
                    header(file)
                    controls(file)
                    Rectangle().fill(tk.bd2).frame(height: 1)
                    content(file)
                }
            } else {
                ReviewEmptyState(title: "Nothing selected",
                                 message: "Pick a file on the canvas or in the tree.", tk: tk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tk.surf2)
    }

    private func header(_ file: ChangedFile) -> some View {
        let review = model.review(for: file.path)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(file.status.label)
                    .font(ReviewFont.caption(10))
                    .foregroundStyle(file.status.color(tk))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(file.status.color(tk)))
                Text(file.path)
                    .font(ReviewFont.mono(14, weight: .medium))
                    .foregroundStyle(tk.t1)
                    .strikethrough(file.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let added = file.added {
                    Text("+\(added)").font(ReviewFont.mono(12)).foregroundStyle(tk.diffAdd)
                }
                if let removed = file.removed {
                    Text("−\(removed)").font(ReviewFont.mono(12)).foregroundStyle(tk.diffDel)
                }
                Button { model.diffOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
            }
            HStack(spacing: 14) {
                if let old = file.oldPath { Text("renamed from \(old)") }
                if file.isUntracked { Text("untracked") }
                Text(review.state.label)
                    .foregroundStyle(ReviewGlyph.of(review, hasOpenIssues: false).color(tk))
                if review.changedSinceReviewed {
                    Text("changed since reviewed").foregroundStyle(tk.warn)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(tk.t3)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func controls(_ file: ChangedFile) -> some View {
        let reviewed = model.review(for: file.path).state == .reviewed
        return HStack(spacing: 8) {
            Picker("Layout", selection: $model.layout) {
                Text("Side by side").tag(DiffLayout.split)
                Text("Unified").tag(DiffLayout.unified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            HStack(spacing: 2) {
                Button { model.jumpStop(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                Text(model.stopLabel)
                    .font(ReviewFont.mono(11))
                    .foregroundStyle(tk.t2)
                    .frame(minWidth: 36)
                Button { model.jumpStop(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
            }
            .help("Previous / next change  [ ]")
            ReviewButton(title: model.fullFile ? "Hunks" : "Full file", hint: "E", tk: tk) {
                Task { await model.toggleFullFile() }
            }
            Spacer()
            ReviewButton(title: reviewed ? "Reviewed ✓" : "Mark reviewed", hint: "R",
                         prominent: !reviewed, tk: tk) {
                Task { await model.toggleReviewed() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func content(_ file: ChangedFile) -> some View {
        switch model.diff {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            ReviewEmptyState(title: "Binary file changed", message: "There is no line diff to show.", tk: tk)
        case .tooLarge(let lines):
            ReviewEmptyState(title: "Large diff hidden",
                             message: lines.map { "\($0) changed lines." }
                                 ?? "This untracked file is too large to count.",
                             tk: tk) {
                ReviewButton(title: "Load anyway", tk: tk) { Task { await model.loadAnyway() } }
            }
        case .failed(let message):
            ReviewEmptyState(title: "Couldn't load the diff", message: message, tk: tk) {
                ReviewButton(title: "Retry", tk: tk) { Task { await model.reloadSelectedDiff() } }
            }
        case .loaded(let diff):
            ReviewDiffRows(model: model, diff: diff, path: file.path, tk: tk)
        }
    }
}
