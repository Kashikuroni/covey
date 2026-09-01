import SwiftUI

enum PanelLabelRole {
    case zone(active: Bool)
    case project
    /// Имя сессии рядом с зоной в заголовке панели.
    case paneSession
}

func panelLabelColor(_ role: PanelLabelRole, tk: Tokens) -> Color {
    switch role {
    case .zone(let active):
        return active ? tk.accent : tk.t1
    case .project:
        return tk.t1
    case .paneSession:
        return tk.t3
    }
}

/// Заголовок agent-панели: зона плюс имя сессии, чтобы панели сплита
/// различались. Плейсхолдер (сессии ещё нет) показывает только зону.
func paneHeaderParts(label: String, name: String) -> (zone: String, session: String?) {
    (zone: label, session: name.isEmpty ? nil : name)
}

/// Zone header caption. Keyboard navigation is documented in the status bar.
func zoneTitle(_ title: String, zone _: FocusZone, active: Bool, tk: Tokens) -> some View {
    Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(panelLabelColor(.zone(active: active), tk: tk))
}
