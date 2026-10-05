import SwiftUI

/// The right panel for a file outside the change: its text read-only, usage
/// lines highlighted, scrolled to the clicked one. No comments, no issues.
struct ReviewFileTextPanel: View {
    @Bindable var model: ReviewModel
    let view: ReviewFileView
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(tk.bd2).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tk.surf2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("READ-ONLY")
                    .font(ReviewFont.caption(10))
                    .foregroundStyle(tk.t3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                Text(view.path)
                    .font(ReviewFont.mono(14, weight: .medium))
                    .foregroundStyle(tk.t1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button { model.closeFileView() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
            }
            let caption = ReviewModel.fileViewCaption(inChange: model.file(view.path) != nil,
                                                      usageLines: view.highlighted.count)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(tk.t3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch view.content {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ReviewEmptyState(title: "Can't show this file",
                             message: "It is missing, binary, not UTF-8 or larger than 1 MB.", tk: tk)
        case .text(let lines):
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(number: index + 1, text: line).id(index + 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
                // One tick later: the lazy stack must lay out before it can scroll.
                .onChange(of: view, initial: true) { _, current in
                    guard let line = current.line else { return }
                    Task { @MainActor in proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
    }

    private func row(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(number)")
                .font(ReviewFont.mono(11))
                .foregroundStyle(tk.t4)
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, 10)
            Text(text.isEmpty ? " " : text)
                .font(ReviewFont.mono(12))
                .foregroundStyle(tk.t1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(view.highlighted.contains(number) ? tk.accent.opacity(0.16) : Color.clear)
    }
}
