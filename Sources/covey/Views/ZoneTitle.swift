import SwiftUI

/// Zone header caption with its ⌘-digit badge: "Session [1]". The badge is
/// always dim so it never competes with the active-accent title.
func zoneTitle(_ title: String, badge: Int, active: Bool, tk: Tokens) -> some View {
    HStack(spacing: 4) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? tk.accent : tk.t4)
        Text("[\(badge)]")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tk.t4)
    }
}
