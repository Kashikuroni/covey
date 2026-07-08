import SwiftUI

/// Inline markdown (bold/italic/code/links) for one line; falls back to
/// the raw string when parsing fails.
func inlineMD(_ s: String) -> AttributedString {
    (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

/// Obsidian-style line renderer shared by the note preview and the issue
/// body: headings, checkboxes, bullets, rules, quotes, code fences, plain
/// text — with inline bold/italic/mono. One place — identical markdown
/// look everywhere.
struct MarkdownLineView: View {
    let line: NoteLine
    let tk: Tokens

    var body: some View {
        switch line {
        case .heading(let level, let textLine):
            Text(inlineMD(textLine))
                .font(.system(size: level == 1 ? 15 : 13,
                              weight: level == 1 ? .bold : .semibold))
                .padding(.top, 2)
        case .task(let done, let textLine):
            // Obsidian-style checkbox: crisp SF glyph, done fades + strikes.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(done ? AnyShapeStyle(tk.ok.opacity(0.85))
                                          : AnyShapeStyle(tk.t3))
                Text(inlineMD(textLine))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? AnyShapeStyle(.secondary)
                                          : AnyShapeStyle(.primary))
            }
            .font(.callout)
        case .bullet(let textLine):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(tk.t3)
                Text(inlineMD(textLine))
            }
            .font(.callout)
        case .text(let textLine):
            Text(inlineMD(textLine)).font(.callout)
        case .blank:
            Text(" ").font(.caption2)
        case .rule:
            Rectangle().fill(tk.bd2).frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        case .quote(let textLine):
            HStack(alignment: .top, spacing: 7) {
                Rectangle().fill(tk.t4).frame(width: 2)
                Text(inlineMD(textLine)).foregroundStyle(tk.t3)
            }
            .font(.callout)
        case .codeFence:
            // The marker line itself renders as breathing room; the fence
            // reads from the code lines' shared backdrop.
            Spacer().frame(height: 2)
        case .code(let raw):
            Text(raw)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tk.surf2)
        }
    }
}
