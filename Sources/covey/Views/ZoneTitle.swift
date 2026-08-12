import SwiftUI

enum PanelLabelRole {
    case zone(active: Bool)
    case project
}

func panelLabelColor(_ role: PanelLabelRole, tk: Tokens) -> Color {
    switch role {
    case .zone(let active):
        return active ? tk.accent : tk.t1
    case .project:
        return tk.t1
    }
}

/// Zone header caption with its ⌘-digit badge: "Session [1]". The badge is
/// always dim so it never competes with the active-accent title.
func zoneTitle(_ title: String, badge: Int, active: Bool, tk: Tokens) -> some View {
    HStack(spacing: 4) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(panelLabelColor(.zone(active: active), tk: tk))
        Text("[\(badge)]")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tk.t4)
    }
}
