import SwiftUI

/// One comment or issue under its diff line.
struct ReviewThreadItemView: View {
    let item: ReviewThreadItem
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        Group {
            switch item {
            case .comment(let comment): ReviewCommentView(comment: comment, tk: tk)
            case .issue(let issue): ReviewIssueCard(issue: issue, model: model, tk: tk)
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tk.surface)
        .overlay(alignment: .top) { Rectangle().fill(tk.bd2).frame(height: 1) }
    }
}

struct ReviewCommentView: View {
    let comment: ReviewComment
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("You").font(.system(size: 12, weight: .medium)).foregroundStyle(tk.t1)
                Text(comment.createdAt, style: .time).foregroundStyle(tk.t3)
                if let to = comment.sentTo {
                    Text("SENT TO \(to.uppercased())").font(ReviewFont.caption(9.5)).foregroundStyle(tk.t2)
                }
                if let note = comment.note { Text(note).foregroundStyle(tk.warn) }
            }
            .font(.system(size: 12))
            Text(comment.text)
                .font(.system(size: 13))
                .foregroundStyle(tk.t1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

struct ReviewIssueCard: View {
    let issue: ReviewIssue
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("ISSUE #\(issue.id)").font(ReviewFont.caption(10)).foregroundStyle(tk.diffDel)
                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tk.t1)
                    .strikethrough(issue.status == .dismissed)
                Spacer(minLength: 8)
                Text(issue.severity.rawValue.uppercased())
                    .font(ReviewFont.caption(10))
                    .foregroundStyle(issue.severity.color(tk))
            }
            if issue.body != issue.title {
                Text(issue.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tk.t2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let to = issue.sentTo {
                Text("Sent to \(to)").font(.system(size: 11)).foregroundStyle(tk.t3)
            }
            if let note = issue.note {
                Text(note).font(.system(size: 11.5))
                    .foregroundStyle(issue.anchorState == .tracked ? tk.t3 : tk.warn)
            }
            HStack(spacing: 4) {
                ForEach(IssueStatus.allCases, id: \.self) { status in
                    // The styling lives inside the label: a plain button hit-tests
                    // its label only, so the padded box must be the label.
                    Button { model.setStatus(status, forIssue: issue.id) } label: {
                        Text(status.rawValue)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .foregroundStyle(status == issue.status ? tk.bg : tk.t3)
                            .background(status == issue.status ? tk.t1 : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if issue.status == .open {
                    ReviewButton(title: "Send issue to \(model.target?.name ?? "agent") →",
                                 prominent: true, tk: tk) { model.beginSend(issue: issue.id) }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(tk.card)
        .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
        .opacity(issue.status.isActive ? 1 : 0.6)
    }
}

/// Inline composer under the anchored line.
struct ReviewComposerView: View {
    @Bindable var model: ReviewModel
    let tk: Tokens
    @FocusState private var focused: Bool

    var body: some View {
        if let composer = model.composer {
            VStack(alignment: .leading, spacing: 8) {
                Text(ReviewPrompt.location(composer.anchor))
                    .font(ReviewFont.mono(11))
                    .foregroundStyle(tk.t3)
                TextEditor(text: Binding(get: { model.composer?.draft ?? "" },
                                         set: { model.composer?.draft = $0 }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 64, maxHeight: 160)
                    .background(tk.surf2)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                    .focused($focused)
                HStack(spacing: 6) {
                    Text("Severity").font(.system(size: 11)).foregroundStyle(tk.t3)
                    ForEach(IssueSeverity.allCases, id: \.self) { severity in
                        Button { model.composer?.severity = severity } label: {
                            Text(severity.rawValue)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .foregroundStyle(composer.severity == severity ? tk.bg : tk.t2)
                                .background(composer.severity == severity ? severity.color(tk) : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                                .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    ReviewButton(title: "Cancel", tk: tk) { model.composer = nil }
                    ReviewButton(title: "Create issue", tk: tk) { model.submitIssue() }
                    ReviewButton(title: "Comment", prominent: true, tk: tk) { model.submitComment() }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.leading, 58)
            .padding(.trailing, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tk.surface)
            .onAppear { focused = true }
        }
    }
}
