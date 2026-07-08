import SwiftUI

/// Read-only issue detail: pinned header (number, title, state, author,
/// date, labels) over a body-only scroll. The body renders through the
/// shared markdown line renderer; keys live in IssueBrowserPane.
struct IssueDetailView: View {
    let issue: GhIssue
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#\(issue.number)")
                    .font(.system(size: IssueFont.body, design: .monospaced))
                    .foregroundStyle(tk.t3)
                Text(issue.isOpen ? "OPEN" : "CLOSED")
                    .font(.system(size: IssueFont.meta, weight: .bold))
                    .foregroundStyle(issue.isOpen ? tk.ok : tk.t4)
                Spacer()
            }
            Text(issue.title)
                .font(.system(size: IssueFont.title, weight: .semibold))
                .foregroundStyle(tk.t1)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(issue.author)
                    .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t3)
                Text(issue.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
            }
            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels, id: \.name) { label in
                        Text(label.name)
                            .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(tk.surf2, in: Capsule())
                            .overlay(Capsule().strokeBorder(tk.bd2))
                    }
                }
            }
            Divider()
            if issue.body.isEmpty {
                Text("no description")
                    .font(.system(size: IssueFont.body)).foregroundStyle(tk.t4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(parseNote(issue.body).enumerated()),
                                id: \.offset) { _, line in
                            MarkdownLineView(line: line, tk: tk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        // Short content must not float to the pane's center: the detail
        // block owns all available space, pinned to the top (and pushes the
        // pane's hint row to the bottom, like the pre-split-scroll layout).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
