import Foundation
import CoveyKit

/// Stable identity of a workspace view — survives losing any single member
/// session, so a split never "falls apart" when one leaf dies.
typealias ViewID = String

/// The terminal zone of a view: a covey-owned hidden shell shown as the right
/// column (`.vertical`, ⌘T) or the bottom band (`.horizontal`, ⌘⇧T).
/// `shellSession == nil` while the zone is open but the daemon session
/// is not yet linked (spawn pending, or a relink after a daemon restart).
struct TerminalZone: Equatable {
    var shellSession: String?
    var axis: PaneAxis

    init(shellSession: String?, axis: PaneAxis = .vertical) {
        self.shellSession = shellSession
        self.axis = axis
    }
}

/// The inspector zone of a view. Content (issues by project root, trace by the
/// focused session) is still resolved by `AppModel`; the view only remembers
/// whether the drawer is open and which drawer.
enum InspectorZone: Equatable {
    case hidden
    case shown(mode: AppModel.InspectorMode)

    var isShown: Bool { if case .shown = self { return true }; return false }
    var mode: AppModel.InspectorMode? { if case .shown(let m) = self { return m }; return nil }

    /// Persisted form: `InspectorMode.rawValue` when open, nil when hidden.
    init(persistedString s: String?) {
        self = s.flatMap(AppModel.InspectorMode.init(rawValue:)).map(InspectorZone.shown) ?? .hidden
    }
    var persistedString: String? { mode?.rawValue }
}

/// One workspace view: the agent-pane tree plus its optional terminal and
/// inspector zones. A view with one leaf is an ordinary single pane; ≥2 leaves
/// is a Split View. Views are never empty — the last leaf leaving deletes it.
struct WorkspaceView: Identifiable, Equatable {
    let id: ViewID
    var agentTree: PaneNode
    var terminal: TerminalZone?
    var inspector: InspectorZone
    /// Width share of the agent zone vs. the terminal column (0.15…0.85).
    /// nil = never sized for a terminal; the renderer falls back to a default.
    var agentAreaRatio: Double?

    static func single(_ session: String, id: ViewID) -> WorkspaceView {
        WorkspaceView(id: id, agentTree: .agent(session: session),
                      terminal: nil, inspector: .hidden, agentAreaRatio: nil)
    }

    var leaves: [String] { agentTree.leaves }
    var isSplit: Bool { agentTree.leafCount > 1 }

    /// Rewrites a leaf name (session rename). No-op if `old` is absent.
    mutating func renameLeaf(_ old: String, to new: String) {
        agentTree = agentTree.replacing(session: old, with: new)
    }

    /// Removes a leaf and collapses its node. Returns the focus successor (nil
    /// if the leaf was absent or it was the last one). When `emptied` is true
    /// the caller must drop the view.
    mutating func removeLeaf(_ session: String) -> (successor: String?, emptied: Bool) {
        guard agentTree.contains(session: session) else { return (nil, false) }
        if agentTree.leafCount == 1 { return (nil, true) }
        let (rest, successor) = agentTree.removing(session: session)
        if let rest {
            agentTree = rest
        } else if let successor {
            agentTree = .agent(session: successor)
        }
        return (successor, false)
    }
}

extension WorkspaceView {
    init(persisted p: PersistedWorkspaceView) {
        let terminal = (p.terminalShell != nil || p.terminalOpen == true)
            ? TerminalZone(shellSession: p.terminalShell,
                           axis: p.terminalAxis.flatMap(PaneAxis.init(rawValue:)) ?? .vertical)
            : nil
        self.init(id: p.id,
                  agentTree: PaneNode(persisted: p.agentTree),
                  terminal: terminal,
                  inspector: InspectorZone(persistedString: p.inspector),
                  agentAreaRatio: p.agentAreaRatio)
    }

    var persisted: PersistedWorkspaceView {
        PersistedWorkspaceView(
            id: id,
            agentTree: agentTree.persisted,
            terminalShell: terminal?.shellSession,
            terminalOpen: terminal != nil ? true : nil,
            terminalAxis: terminal?.axis == .horizontal ? PaneAxis.horizontal.rawValue : nil,
            inspector: inspector.persistedString,
            agentAreaRatio: agentAreaRatio)
    }
}
