import SwiftUI

/// Work-in-progress signals for one issue, precomputed by the pane —
/// the card itself is model-free and dumb.
struct IssueWip: Equatable {
    var sessionName: String? = nil
    var sessionTint: Color? = nil
    var branch: String? = nil
    var added: UInt32? = nil
    var removed: UInt32? = nil
    var prNumber: Int? = nil

    var isEmpty: Bool { sessionName == nil && branch == nil && prNumber == nil }
    /// True when the bound session has uncommitted changes to show as +N/−N.
    var hasDiff: Bool { (added ?? 0) > 0 || (removed ?? 0) > 0 }
}

struct IssueCardLabelPlan: Equatable {
    var visible: [GhLabel]
    var counter: String?
}

func issueCardLabelPlan(_ labels: [GhLabel], limit: Int = 2) -> IssueCardLabelPlan {
    let shown = min(max(0, limit), labels.count)
    return IssueCardLabelPlan(
        visible: Array(labels.prefix(shown)),
        counter: labels.count > shown ? "\(shown)/\(labels.count)" : nil)
}

func issueCardUpdatedText(age: String) -> String {
    "updated \(age)"
}

/// A 1pt dashed guide line — SwiftUI has no dashed-border modifier.
private struct DashedLine: Shape {
    var horizontal: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if horizontal {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        return p
    }
}

/// Issue row, variant 3a "rail + time": a fixed left rail (issue number top,
/// relative age bottom, dashed divider) and a content column (title, optional
/// description, labels + author, optional session/WIP block). Focus is a single
/// accent ring; open/closed reads from the title color. Model-free — every
/// signal is precomputed by the pane.
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
        HStack(alignment: .top, spacing: 13) {
            rail
            content
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tk.card, in: RoundedRectangle(cornerRadius: Tokens.rLg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.rLg).strokeBorder(tk.bd))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Tokens.rLg)
                    .strokeBorder(tk.accent.opacity(0.55), lineWidth: 2)
            }
        }
    }

    // Left rail: number pinned top, age pinned bottom, dashed trailing divider.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("#\(issue.number)")
                .font(mono(IssueFont.cardNum, .semibold)).foregroundStyle(tk.t3)
            Spacer(minLength: 0)
            Text(age)
                .font(mono(IssueFont.cardTime)).foregroundStyle(tk.t4)
        }
        .padding(.trailing, 13)
        .frame(width: 52, alignment: .leading)
        .frame(minHeight: 44, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            DashedLine(horizontal: false)
                .stroke(tk.bd2, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 1)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.title)
                .font(.system(size: IssueFont.cardTitle, weight: .semibold))
                .foregroundStyle(issue.isOpen ? tk.t1 : tk.t3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let desc = issueDescription(issue.body) {
                Text(desc)
                    .font(.system(size: IssueFont.cardDesc))
                    .foregroundStyle(tk.t3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !issue.labels.isEmpty || !issue.author.isEmpty {
                labelRow
            }
            if !wip.isEmpty {
                wipBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // At most 2 chips so the row never wraps into a cluttered stack; the rest
    // collapse into a `shown/total` counter. Labels use a smaller type than the
    // author so they read as secondary metadata.
    private var labelRow: some View {
        let shown = min(2, issue.labels.count)
        return HStack(spacing: 13) {
            HStack(spacing: 10) {
                ForEach(issue.labels.prefix(shown), id: \.name) { label in
                    let c = labelChipColors(hex: label.color, darkTheme: tk.isDark)
                    HStack(spacing: 5) {
                        Circle().frame(width: 6, height: 6)
                            .foregroundStyle(c.map { Color(hex: $0.dot) } ?? tk.t3)
                        Text(label.name)
                            .lineLimit(1)
                            .foregroundStyle(c.map { Color(hex: $0.text) } ?? tk.t2)
                    }
                }
                if issue.labels.count > shown {
                    Text("\(shown)/\(issue.labels.count)").foregroundStyle(tk.t4)
                }
            }
            .font(.system(size: IssueFont.cardLabel, design: .monospaced))
            Spacer(minLength: 4)
            if !issue.author.isEmpty {
                Text("@\(issue.author)").foregroundStyle(tk.t4)
                    .font(.system(size: IssueFont.cardMeta, design: .monospaced))
            }
        }
    }

    private var wipBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let name = wip.sessionName {
                Text(name)
                    .font(mono(IssueFont.cardSession, .semibold))
                    .foregroundStyle(wip.sessionTint ?? tk.t3)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { onSessionTap?() }
            }
            HStack(spacing: 8) {
                if let branch = wip.branch {
                    Text("⎇").foregroundStyle(tk.t3)
                    Text(branch).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(tk.t3)
                }
                Spacer(minLength: 4)
                if let a = wip.added, a > 0 {
                    Text("+\(a)").fontWeight(.bold).foregroundStyle(tk.diffAdd)
                }
                if let d = wip.removed, d > 0 {
                    Text("−\(d)").fontWeight(.bold).foregroundStyle(tk.diffDel)
                }
                if let pr = wip.prNumber {
                    Text("⇄ #\(pr)").foregroundStyle(tk.t3)
                }
            }
            .font(mono(IssueFont.cardSession))
        }
        .padding(.top, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            DashedLine(horizontal: true)
                .stroke(tk.bd2, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(height: 1)
        }
    }
}
