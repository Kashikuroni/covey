import SwiftUI

/// Which-key panel for the Space leader (port of amux-tui ui/leader.rs).
struct WhichKeyView: View {
    let menu: LeaderMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(menu.rows, id: \.key) { row in
                HStack(spacing: 8) {
                    Text(row.key).fontWeight(.bold).monospaced()
                        .frame(width: 16, alignment: .leading)
                    Text(row.label)
                }
                .font(.callout)
                .foregroundStyle(row.implemented ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            Text(menu == .root ? "esc close" : "backspace back · esc close")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .shadow(radius: 8)
    }

    private var title: String {
        switch menu {
        case .root: return "space —"
        case .git: return "space g — git"
        case .session: return "space s — session"
        case .terminal: return "space t — terminal"
        case .ui: return "space u — ui"
        case .project: return "space p — project"
        }
    }
}
