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

func issueCardIsHighlighted(selected: Bool, inspectorFocused: Bool) -> Bool {
    selected && inspectorFocused
}

/// A 1pt horizontal dashed guide above the session/WIP block.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Issue row with a compact header/description/labels/WIP/footer hierarchy.
/// Focus is a single accent ring; open/closed reads from the title color.
/// Model-free — every signal is precomputed by the pane.
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
        VStack(alignment: .leading, spacing: 8) {
            header
            if let description = issueDescription(issue.body) {
                Text(description)
                    .font(.system(size: IssueFont.cardDesc))
                    .foregroundStyle(tk.t3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !issue.labels.isEmpty {
                labelRow
            }
            if !wip.isEmpty {
                wipBlock
            }
            footer
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#\(issue.number)")
                .font(mono(IssueFont.cardNum, .semibold))
                .foregroundStyle(tk.t3)
                .fixedSize(horizontal: true, vertical: false)
            Text(issue.title)
                .font(.system(size: IssueFont.cardTitle, weight: .semibold))
                .foregroundStyle(issue.isOpen ? tk.t1 : tk.t3)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var labelRow: some View {
        let plan = issueCardLabelPlan(issue.labels)
        return HStack(spacing: 6) {
            ForEach(plan.visible, id: \.name) { label in
                labelPill(label)
                    .layoutPriority(-1)
            }
            if let counter = plan.counter {
                Text(counter)
                    .foregroundStyle(tk.t4)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: IssueFont.cardLabel, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelPill(_ label: GhLabel) -> some View {
        let rgb = labelPillColor(hex: label.color, darkTheme: tk.isDark)
        let color = rgb.map { Color(hex: $0) }
        return Text(label.name)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(color ?? tk.t2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color?.opacity(0.12) ?? tk.surf2, in: Capsule())
            .overlay {
                Capsule().strokeBorder(color?.opacity(0.70) ?? tk.bd2)
            }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !issue.author.isEmpty {
                Text("@\(issue.author)")
            }
            Spacer(minLength: 4)
            Text(issueCardUpdatedText(age: age))
        }
        .font(.system(size: IssueFont.cardMeta, design: .monospaced))
        .foregroundStyle(tk.t2)
        .frame(maxWidth: .infinity)
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
            DashedLine()
                .stroke(tk.bd2, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(height: 1)
        }
    }
}
