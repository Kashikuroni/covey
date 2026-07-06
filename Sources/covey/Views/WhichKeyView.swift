import SwiftUI

/// Which-key panel for the Space leader (port of amux-tui ui/leader.rs).
struct WhichKeyView: View {
    let menu: LeaderMenu

    private struct Row: Identifiable {
        let id = UUID()
        let key: String
        let label: String
        let implemented: Bool
    }

    private var rows: [Row] {
        switch menu {
        case .root: return [
            Row(key: "g", label: "git — issue · promote · delete branch · cleanup · return", implemented: true),
            Row(key: "s", label: "session — rename · restart · verify · nvim", implemented: true),
            Row(key: "a", label: "app — usage log · restart claude", implemented: true),
            Row(key: "t", label: "terminal — split v · split h · close", implemented: true),
        ]
        case .git: return [
            Row(key: "i", label: "create github issue", implemented: true),
            Row(key: "p", label: "promote worktree to root", implemented: true),
            Row(key: "b", label: "delete session branch", implemented: true),
            Row(key: "c", label: "cleanup merged branches", implemented: true),
            Row(key: "r", label: "return to repo root", implemented: true),
        ]
        case .session: return [
            Row(key: "r", label: "rename session", implemented: true),
            Row(key: "R", label: "rename project (later)", implemented: false),
            Row(key: "u", label: "restart session", implemented: true),
            Row(key: "v", label: "verify / cancel (later)", implemented: false),
            Row(key: "V", label: "verification details (later)", implemented: false),
            Row(key: "e", label: "nvim in agent dir (later)", implemented: false),
        ]
        case .app: return [
            Row(key: "l", label: "usage log (later)", implemented: false),
            Row(key: "u", label: "restart all claude sessions", implemented: true),
            Row(key: "t", label: "toggle dark / light theme", implemented: true),
        ]
        case .terminal: return [
            Row(key: "v", label: "vertical split — shell beside agent", implemented: true),
            Row(key: "h", label: "horizontal split — shell below agent", implemented: true),
            Row(key: "x", label: "close split", implemented: true),
        ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(rows) { row in
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
        case .app: return "space a — app"
        case .terminal: return "space t — terminal"
        }
    }
}
