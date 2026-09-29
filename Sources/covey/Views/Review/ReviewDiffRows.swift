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
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !outdated.isEmpty {
                        Text("NOT ON A CURRENT LINE")
                            .font(ReviewFont.caption(10))
                            .foregroundStyle(tk.warn)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        ForEach(outdated) { item in ReviewThreadItemView(item: item, model: model, tk: tk) }
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
                                annotations(for: splitKeys(row), threads: threads)
                            }
                        } else {
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                                UnifiedRowView(line: line, model: model, tk: tk)
                                    .id(DiffSplitLayout.rowID(hunk: hunkIndex, line: index))
                                annotations(for: unifiedKeys(line), threads: threads)
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

    /// Old-side keys exist only for removed lines: context lines are anchored on the new side.
    private func splitKeys(_ row: SplitRow) -> [ThreadKey] {
        var keys: [ThreadKey] = []
        if let left = row.left, left.kind == .removed, let n = left.oldNumber {
            keys.append(ThreadKey(side: .old, line: n))
        }
        if let right = row.right, let n = right.newNumber {
            keys.append(ThreadKey(side: .new, line: n))
        }
        return keys
    }

    private func unifiedKeys(_ line: DiffLine) -> [ThreadKey] {
        if let n = line.newNumber { return [ThreadKey(side: .new, line: n)] }
        if let n = line.oldNumber { return [ThreadKey(side: .old, line: n)] }
        return []
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
