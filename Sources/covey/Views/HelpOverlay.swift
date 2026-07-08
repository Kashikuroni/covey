import SwiftUI

/// Keyboard reference (port of amux-tui modal_help, keys tab only).
struct HelpOverlay: View {
    private let groups: [(String, [(String, String)])] = [
        ("navigate", [
            ("j / k", "next / previous session"),
            ("g", "first session"),
            ("s then 1-9", "jump to visible session"),
            ("/", "filter sessions"),
        ]),
        ("act", [
            ("enter / o", "focus terminal (recent: relaunch)"),
            ("⌃q", "leave terminal back to the list"),
            ("n / N", "new session (N: same project)"),
            ("r", "recent sessions"),
            ("t", "project note"),
            ("d", "kill session"),
            ("K / J", "move session up / down"),
        ]),
        ("view", [
            ("[ ] { }", "resize split"),
            ("⌃h / ⌃l", "cycle focus: list · agent · shell · inspector"),
            ("⌃\\", "toggle split pane focus"),
            ("⌃k / ⌃j", "scroll terminal page up / down"),
            ("⌃h/⌃l (inspector)", "note/issue tab"),
            ("⌘1-5", "zones: session · agent · note · issues · terminal"),
            ("j/k · enter · e/c/x · s/g (issues)", "nav · view · edit/close/delete · session new/jump"),
            ("G / end", "terminal to bottom"),
        ]),
        ("leader (space)", [
            ("g", "git: issue · list issues · promote · delete branch · cleanup · return"),
            ("s", "session: rename · restart · restart all · verify (later) · nvim (later)"),
            ("t", "terminal: split v · split h · close"),
            ("u", "ui: sessions · inspector · footer · header · theme"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keys").font(.headline)
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.0).font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(group.1, id: \.0) { key, label in
                        HStack(spacing: 10) {
                            Text(key).monospaced().fontWeight(.bold)
                                .frame(width: 90, alignment: .leading)
                            Text(label).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            Text("any key closes").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .shadow(radius: 12)
    }
}
