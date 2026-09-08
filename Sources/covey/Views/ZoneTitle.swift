import SwiftUI

enum PanelLabelRole {
    case zone(active: Bool)
    case project
    /// Вторая строка заголовка панели — «<проект> - <сессия>».
    case paneSubject
}

func panelLabelColor(_ role: PanelLabelRole, tk: Tokens) -> Color {
    switch role {
    case .zone(let active):
        return active ? tk.accent : tk.t1
    case .project:
        return tk.t1
    case .paneSubject:
        return tk.t1
    }
}

/// Вторая строка заголовка панели, под зоной.
///
/// У agent-панели — «<проект> - <сессия>»: имени сессии мало, когда в сплите
/// стоят сессии разных проектов. У шелл-колонки — только проект: её сессия
/// служебная (скрытый шелл со сгенерированным именем), показывать там нечего.
/// nil — плейсхолдер без сессии: остаётся одна зона.
func paneHeaderSubject(project: String?, session: String, isShell: Bool) -> String? {
    guard !session.isEmpty else { return nil }
    guard let project, !project.isEmpty else { return session }
    return isShell ? project : "\(project) - \(session)"
}

/// Zone header caption. Keyboard navigation is documented in the status bar.
func zoneTitle(_ title: String, zone _: FocusZone, active: Bool, tk: Tokens) -> some View {
    Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(panelLabelColor(.zone(active: active), tk: tk))
}
