import SwiftUI

let helpGroups: [(String, [(String, String)])] = [
    ("navigate", [
        ("j / k", "next / previous session"),
        ("g", "first session"),
        ("s then 1-9", "jump to visible session"),
        ("/", "filter / search sessions"),
    ]),
    ("act", [
        ("⌘P", "command palette"),
        ("enter", "open session in Agent"),
        ("h", "restore Recent and keep browsing"),
        ("⌃q", "leave terminal back to the list"),
        ("n / N", "new session (N: same project)"),
        ("r", "recent sessions"),
        ("d", "kill session"),
        ("K / J", "move session up / down"),
    ]),
    ("view", [
        ("[ ] { }", "resize split"),
        ("⌃h / ⌃l", "cycle focus: list · agent · shell · inspector"),
        ("⌃\\", "toggle split pane focus"),
        ("⌃k / ⌃j", "scroll terminal page up / down"),
        ("⌘1-5", "zones: session · agent · issues · terminal · trace"),
        ("j/k · enter · e/c/x · s/g (issues)",
         "nav · view · edit/close/delete · session new/jump"),
        ("G / end", "terminal to bottom"),
    ]),
    ("leader (space)", [
        ("g", "git: issue · list issues · promote · delete branch · cleanup · return"),
        ("s", "session: rename · restart · restart all · verify (later) · nvim (later)"),
        ("t", "terminal: split v · split h · close"),
        ("u", "ui: sessions · inspector · footer · header · theme"),
    ]),
]

/// Keyboard reference (port of amux-tui modal_help, keys tab only).
struct HelpOverlay: View {
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keys").font(.headline)
            ForEach(helpGroups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.0).font(.caption).fontWeight(.semibold)
                        .foregroundStyle(tk.t4)
                    ForEach(group.1, id: \.0) { key, label in
                        KbdBadge(key: key, label: label, tk: tk)
                    }
                }
            }
            KbdBadge(key: "any key", label: "close", tk: tk)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .shadow(radius: 12)
    }
}
