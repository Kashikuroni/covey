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

    static let minSessionSplitPercent = 15
    static let maxSessionSplitPercent = 90
    static let minInspectorWidth = 240
    static let maxInspectorWidth = 1200

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

    // MARK: - Split tree (Split Session)

    /// Пол одной agent-панели сплита; при переполнении деградирует (см. ниже).
    static let minSplitPane: CGFloat = 120
    static let minSplitRatio: Double = 0.15
    static let maxSplitRatio: Double = 0.85

    /// Размер первой ветки узла: драг-кламп 0.15–0.85, затем пол 120pt на лист
    /// обеих веток; когда пол невыполним (120 × листьев > usable), равный дележ —
    /// размер пропорционален числу листьев, ratio игнорируется (спека).
    static func firstBranchSize(requested: Double, available: CGFloat,
                                firstLeaves: Int, secondLeaves: Int,
                                gutter: CGFloat) -> CGFloat {
        let usable = max(0, available - gutter)
        guard usable > 0 else { return 0 }
        let total = max(1, firstLeaves + secondLeaves)
        let leafFloor = min(minSplitPane, usable / CGFloat(total))
        let minFirst = leafFloor * CGFloat(firstLeaves)
        let maxFirst = usable - leafFloor * CGFloat(secondLeaves)
        if minFirst >= maxFirst {
            return usable * CGFloat(firstLeaves) / CGFloat(total)
        }
        let clamped = usable * min(maxSplitRatio, max(minSplitRatio, requested))
        return min(max(clamped, minFirst), maxFirst)
    }

    /// Делята дерева: путь узла (index-path) для записи ratio драгом.
    struct SplitDivider: Equatable {
        let path: [Int]
        let axis: PaneAxis
        /// Прямоугольник всего узла в координатах split-области.
        let bounds: CGRect
    }

    struct SplitFrames: Equatable {
        var leaves: [String: CGRect] = [:]
        var companion: CGRect?
        var agentArea: CGRect?
        var dividers: [SplitDivider] = []
    }

    /// Геометрия окна: [agent-дерево | шелл-колонка]; внутри дерева — рекурсия
    /// по `.split`-узлам. Все кадры — в координатной области split-вью.
    ///
    /// `soloAgent` — панель одиночного агента: по инварианту дерева один лист
    /// живёт вне `tree` (`splitTree == nil`), и без него agent-область осталась
    /// бы пустой, когда рядом стоит шелл-колонка. При не-nil дереве игнорируется:
    /// источник истины — дерево.
    static func splitFrames(tree: PaneNode?, soloAgent: String? = nil,
                            companionShell: String?,
                            companionRatio: Double, size: CGSize,
                            gutter: CGFloat) -> SplitFrames {
        var result = SplitFrames()
        let agentLeaves = tree?.leafCount ?? 0
        if companionShell != nil {
            let columnWidth = size.width - firstBranchSize(
                requested: companionRatio, available: size.width,
                firstLeaves: max(agentLeaves, 1), secondLeaves: 1, gutter: gutter)
            let areaWidth = max(0, size.width - columnWidth - gutter)
            result.agentArea = CGRect(x: 0, y: 0, width: areaWidth, height: size.height)
            result.companion = CGRect(x: areaWidth + gutter, y: 0,
                                      width: max(0, columnWidth), height: size.height)
        } else {
            result.agentArea = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        if let tree {
            frames(node: tree, in: result.agentArea!, gutter: gutter,
                   path: [], into: &result)
        } else if let soloAgent {
            result.leaves[soloAgent] = result.agentArea!
        }
        return result
    }

    private static func frames(node: PaneNode, in rect: CGRect, gutter: CGFloat,
                               path: [Int], into result: inout SplitFrames) {
        switch node {
        case .agent(let session):
            result.leaves[session] = rect
        case .split(let axis, let ratio, let first, let second):
            let vertical = axis == .vertical
            let available = vertical ? rect.width : rect.height
            let firstSize = firstBranchSize(requested: ratio, available: available,
                                            firstLeaves: first.leafCount,
                                            secondLeaves: second.leafCount, gutter: gutter)
            let firstRect = vertical
                ? CGRect(x: rect.minX, y: rect.minY, width: firstSize, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSize)
            let secondRect = vertical
                ? CGRect(x: rect.minX + firstSize + gutter, y: rect.minY,
                         width: max(0, rect.width - firstSize - gutter), height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + firstSize + gutter,
                         width: rect.width, height: max(0, rect.height - firstSize - gutter))
            result.dividers.append(SplitDivider(path: path, axis: axis, bounds: rect))
            frames(node: first, in: firstRect, gutter: gutter,
                   path: path + [0], into: &result)
            frames(node: second, in: secondRect, gutter: gutter,
                   path: path + [1], into: &result)
        }
    }
}
