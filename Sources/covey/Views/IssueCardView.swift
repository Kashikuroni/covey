import SwiftUI

/// Work-in-progress signals for one issue, precomputed by the pane —
/// the card itself is model-free and dumb.
struct IssueWip: Equatable {
    var sessionName: String?
    var sessionTint: Color?
    var branch: String?
    var prNumber: Int?

    var isEmpty: Bool { sessionName == nil && branch == nil && prNumber == nil }
}

/// Issue row in the session-card idiom: card fill, hairline border,
/// 2pt state stripe, shadow. Rows collapse when empty.
struct IssueCardView: View {
    let issue: GhIssue
    let selected: Bool
    let age: String
    let wip: IssueWip
    let tk: Tokens
    var onSessionTap: (() -> Void)?

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(issue.number)")
                    .font(mono(IssueFont.mono, .medium)).foregroundStyle(tk.t3)
                Text(issue.title)
                    .font(.system(size: IssueFont.body))
                    .foregroundStyle(selected ? tk.t1 : tk.t2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(age).font(mono(IssueFont.monoSmall)).foregroundStyle(tk.t4)
            }
            if let preview = bodyPreview(issue.body) {
                Text(preview)
                    .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4).lineLimit(1)
            }
            if !issue.labels.isEmpty || !issue.author.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3), id: \.name) { label in
                        Text(label.name)
                            .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(tk.surf2, in: Capsule())
                            .overlay(Capsule().strokeBorder(tk.bd2))
                    }
                    if issue.labels.count > 3 {
                        Text("+\(issue.labels.count - 3)")
                            .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
                    }
                    Spacer(minLength: 4)
                    if !issue.author.isEmpty {
                        Text(issue.author).font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
                    }
                }
            }
            if !wip.isEmpty {
                HStack(spacing: 8) {
                    if let name = wip.sessionName {
                        HStack(spacing: 3) {
                            Text("▸").font(mono(IssueFont.monoSmall))
                            Text(name).font(mono(IssueFont.monoSmall)).lineLimit(1)
                        }
                        .foregroundStyle(wip.sessionTint ?? tk.t3)
                        .contentShape(Rectangle())
                        .onTapGesture { onSessionTap?() }
                    }
                    if let branch = wip.branch {
                        HStack(spacing: 3) {
                            Text("⎇").font(.system(size: 12))
                            Text(branch).font(mono(IssueFont.monoSmall)).lineLimit(1)
                        }
                        .foregroundStyle(tk.t3)
                    }
                    if let pr = wip.prNumber {
                        Text("⇄ #\(pr)").font(mono(IssueFont.monoSmall)).foregroundStyle(tk.t3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(selected ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? tk.t1 : (issue.isOpen ? tk.ok.opacity(0.5) : .clear))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .shadow(color: tk.shadowColor, radius: Tokens.shadowRadius, y: Tokens.shadowY)
    }
}
