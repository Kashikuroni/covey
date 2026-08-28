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

/// Zone header caption. Keyboard navigation is documented in the status bar.
func zoneTitle(_ title: String, zone _: FocusZone, active: Bool, tk: Tokens) -> some View {
    Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(panelLabelColor(.zone(active: active), tk: tk))
}
