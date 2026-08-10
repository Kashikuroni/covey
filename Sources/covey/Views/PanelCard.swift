import SwiftUI

/// A workspace zone drawn as a rounded card floating on the window backdrop.
///
/// Zones apply this themselves rather than the workspace applying it for them:
/// a split zone draws one card per pane, and only the zone knows it is split.
/// Deliberately stateless — focus is shown by the accent zone header, exactly
/// as it was before the cards.
struct PanelCard: ViewModifier {
    let tk: Tokens
    let surface: Color

    func body(content: Content) -> some View {
        content
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.rLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.rLg, style: .continuous)
                    .strokeBorder(tk.bd2, lineWidth: 1)
            )
            .shadow(color: tk.shadowColor, radius: Tokens.shadowRadius, y: Tokens.shadowY)
    }
}

extension View {
    func panelCard(_ tk: Tokens, surface: Color) -> some View {
        modifier(PanelCard(tk: tk, surface: surface))
    }
}
