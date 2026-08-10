import CoreGraphics

/// Widths for the workspace's panel cards, plus the inverse mapping a resize
/// handle needs.
///
/// The cards are inset from the window edges by `Tokens.edge` and separated by
/// `Tokens.gutter`, so the width a zone gets and the drag that sets it must be
/// computed from the same inner width — otherwise the divider drifts from the
/// cursor by the amount the gutters take. Pure arithmetic, so the clamps stay
/// testable.
struct PanelLayout: Equatable {
    /// Width the cards share, once edges and gutters are taken out.
    let inner: CGFloat
    /// Zero when the zone is hidden.
    let sessions: CGFloat
    let terminal: CGFloat
    let inspector: CGFloat

    /// Narrowest the session list may get before a drag stops shrinking it.
    static let minSessions: CGFloat = 220
    /// Width the terminal keeps while the session list grows.
    static let minTerminal: CGFloat = 480
    /// Floor the terminal keeps against the inspector — the same floor
    /// `TerminalPaneView`'s split uses. The drawer, not the agent, is the last
    /// zone to yield: an inspector that ate the whole remaining width would
    /// hand the terminal a zero-width frame, and `CoveyTerminalView` holds
    /// output in an uncapped buffer until it gets a real grid.
    static let minTerminalSliver: CGFloat = 120

    static func make(total: CGFloat, showSessions: Bool, showInspector: Bool,
                     splitPct: Int, sbWidth: Int) -> PanelLayout {
        let gutters = (showSessions ? 1 : 0) + (showInspector ? 1 : 0)
        let inner = max(0, total - Tokens.edge * 2 - Tokens.gutter * CGFloat(gutters))
        // The inspector is capped to always leave the terminal its sliver —
        // and, when the session list is showing, to leave it room too — so a
        // wide `sbWidth` can never squeeze the terminal to zero.
        let inspectorCap = showSessions
            ? max(0, inner - minSessions - minTerminalSliver)
            : max(0, inner - minTerminalSliver)
        let inspector = showInspector ? min(CGFloat(sbWidth), inspectorCap) : 0
        // The percentage applies to the whole inner width (as it did to the
        // whole window before the cards). Sessions is capped to reserve room for
        // both minTerminal and inspector, and further capped to not exceed the
        // space remaining after inspector. On a window too narrow for both
        // minimums the session list yields, because a card that overflows would
        // be drawn off-window.
        let sessions = showSessions
            ? min(max(minSessions, min(inner - minTerminal - inspector, inner * CGFloat(splitPct) / 100)),
                  max(0, inner - inspector))
            : 0
        return PanelLayout(inner: inner,
                           sessions: sessions,
                           terminal: max(0, inner - sessions - inspector),
                           inspector: inspector)
    }

    /// Split percentage for a drag measured in the workspace coordinate space,
    /// whose origin sits at the window's content edge — hence dropping
    /// `Tokens.edge` before dividing. `AppModel.setSplitPct` clamps the range.
    static func splitPercent(dragX: CGFloat, inner: CGFloat) -> Int {
        guard inner > 0 else { return 0 }
        return Int(((dragX - Tokens.edge) / inner * 100).rounded())
    }

    /// Inspector width for a drag measured the same way, against the full
    /// workspace width. `AppModel.setSbWidth` clamps the range.
    static func inspectorWidth(dragX: CGFloat, total: CGFloat) -> Int {
        Int(total - Tokens.edge - dragX)
    }
}
