import SwiftUI
import CoveyGit

struct ReviewDiffRows: View {
    @Bindable var model: ReviewModel
    let diff: FileDiff
    let path: String
    let tk: Tokens

    var body: some View {
        let threads = model.threads(for: path)
        let outdated = model.outdatedItems(for: path)
        // Items (and a composer) on a line this diff does not render would
        // otherwise vanish: outside every hunk, or an old-side anchor on a
        // line that is context again. They are listed on top instead.
        let rendered = DiffSplitLayout.renderedKeys(diff, layout: model.layout)
        let unshown = model.unshownItems(for: path, rendered: rendered)
        let composerUnshown = model.composer.map {
            $0.anchor.path == path && !rendered.contains($0.anchor.threadKey)
        } ?? false
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !outdated.isEmpty {
                        sectionHeader("NOT ON A CURRENT LINE")
                        ForEach(outdated) { item in ReviewThreadItemView(item: item, model: model, tk: tk) }
                    }
                    if !unshown.isEmpty || composerUnshown {
                        sectionHeader(model.fullFile ? "NOT ON A SHOWN LINE"
                                                     : "NOT ON A SHOWN LINE — PRESS E FOR THE FULL FILE")
                        ForEach(unshown) { item in ReviewThreadItemView(item: item, model: model, tk: tk) }
                        if composerUnshown { ReviewComposerView(model: model, tk: tk) }
                    }
                    if diff.hunks.isEmpty {
                        Text("No line changes — mode or metadata only.")
                            .font(.system(size: 12))
                            .foregroundStyle(tk.t3)
                            .padding(20)
                    }
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                        Text(hunk.header)
                            .font(ReviewFont.mono(11))
                            .foregroundStyle(tk.t3)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .background(tk.surface)
                        if model.layout == .split {
                            ForEach(DiffSplitLayout.rows(hunk, hunkIndex: hunkIndex)) { row in
                                SplitRowView(row: row, model: model, tk: tk).id(row.id)
                                annotations(for: DiffSplitLayout.splitKeys(row), threads: threads)
                            }
                        } else {
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                                UnifiedRowView(line: line, model: model, tk: tk)
                                    .id(DiffSplitLayout.rowID(hunk: hunkIndex, line: index))
                                annotations(for: DiffSplitLayout.unifiedKeys(line), threads: threads)
                            }
                        }
                    }
                    Text("Click a line number to comment or open an issue.  [ ] changes · J K files · C comment")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tk.t3)
                        .padding(20)
                }
            }
            // `initial: true`: opening an issue reloads the diff, which tears this
            // view down and mounts it again with the request already set. The
            // scroll waits one tick so the lazy stack has laid out, and the request
            // is consumed so a later remount never replays a stale one.
            .onChange(of: model.scrollRequest, initial: true) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(request.rowID, anchor: .top) }
                    if model.scrollRequest == request { model.scrollRequest = nil }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ReviewFont.caption(10))
            .foregroundStyle(tk.warn)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func annotations(for keys: [ThreadKey], threads: [ThreadKey: [ReviewThreadItem]]) -> some View {
        ForEach(keys, id: \.self) { key in
            ForEach(threads[key] ?? []) { item in ReviewThreadItemView(item: item, model: model, tk: tk) }
            if let composer = model.composer, composer.anchor.path == path,
               composer.anchor.side == key.side, composer.anchor.line == key.line {
                ReviewComposerView(model: model, tk: tk)
            }
        }
    }
}

struct DiffNumberCell: View {
    let number: Int?
    let clickable: Bool
    let tk: Tokens
    let action: () -> Void

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(ReviewFont.mono(11))
            .foregroundStyle(tk.t4)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onTapGesture { if clickable { action() } }
            .help(clickable ? "Comment on this line" : "")
    }
}

struct DiffCodeCell: View {
    let text: String?
    let background: Color
    let tk: Tokens

    var body: some View {
        Text(text ?? " ")
            .font(ReviewFont.mono(12))
            .foregroundStyle(tk.t1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
    }
}

private struct SplitRowView: View {
    let row: SplitRow
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 0) {
            DiffNumberCell(number: row.left?.oldNumber, clickable: row.left?.kind == .removed, tk: tk) {
                if let left = row.left, let n = left.oldNumber { model.openComposer(side: .old, line: n, text: left.text) }
            }
            DiffCodeCell(text: row.left?.text, background: background(row.left), tk: tk)
            Rectangle().fill(tk.bd2).frame(width: 1)
            DiffNumberCell(number: row.right?.newNumber, clickable: row.right?.newNumber != nil, tk: tk) {
                if let right = row.right, let n = right.newNumber { model.openComposer(side: .new, line: n, text: right.text) }
            }
            DiffCodeCell(text: row.right?.text, background: background(row.right), tk: tk)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return tk.surface.opacity(0.6) }
        switch line.kind {
        case .added: return tk.diffAdd.opacity(0.12)
        case .removed: return tk.diffDel.opacity(0.12)
        case .context: return .clear
        }
    }
}

private struct UnifiedRowView: View {
    let line: DiffLine
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 0) {
            DiffNumberCell(number: line.oldNumber, clickable: line.kind == .removed, tk: tk) {
                if let n = line.oldNumber { model.openComposer(side: .old, line: n, text: line.text) }
            }
            DiffNumberCell(number: line.newNumber, clickable: line.newNumber != nil, tk: tk) {
                if let n = line.newNumber { model.openComposer(side: .new, line: n, text: line.text) }
            }
            Text(sign)
                .font(ReviewFont.mono(12))
                .foregroundStyle(signColor)
                .frame(width: 16)
            DiffCodeCell(text: line.text, background: .clear, tk: tk)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: return tk.diffAdd
        case .removed: return tk.diffDel
        case .context: return tk.t4
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return tk.diffAdd.opacity(0.12)
        case .removed: return tk.diffDel.opacity(0.12)
        case .context: return .clear
        }
    }
}
