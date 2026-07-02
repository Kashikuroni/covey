import SwiftUI

/// Keyboard reference (port of amux-tui modal_help, keys tab only).
struct HelpOverlay: View {
    private let groups: [(String, [(String, String)])] = [
        ("navigate", [
            ("j / k", "next / previous session"),
            ("g", "first session"),
            ("s then 1-9", "jump to visible session"),
            ("tab", "active / recent tab"),
            ("/", "filter sessions"),
        ]),
        ("act", [
            ("enter / o", "focus terminal (recent: relaunch)"),
            ("⌃q", "leave terminal back to the list"),
            ("n / N", "new session (N: same project)"),
            ("d", "kill session"),
            ("K / J", "move session up / down"),
        ]),
        ("view", [
            ("[ ] { }", "resize split"),
            ("⌃k / ⌃j", "scroll terminal page up / down"),
            ("G / end", "terminal to bottom"),
        ]),
        ("leader (space)", [
            ("g", "git: issue · promote · delete branch · cleanup (later)"),
            ("s", "session: rename · verify (later) · nvim (later)"),
            ("a", "app: usage log · restart claude (later)"),
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
    }
}
