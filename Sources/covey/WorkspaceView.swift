import Foundation
import CoveyKit

/// Stable identity of a workspace view — survives losing any single member
/// session, so a split never "falls apart" when one leaf dies.
typealias ViewID = String

/// The terminal zone of a view: a covey-owned hidden shell shown as the right
/// column. `shellSession == nil` while the zone is open but the daemon session
/// is not yet linked (spawn pending, or a relink after a daemon restart).
struct TerminalZone: Equatable {
    var shellSession: String?
}

/// The inspector zone of a view. Content (issues by project root, trace by the
/// focused session) is still resolved by `AppModel`; the view only remembers
/// whether the drawer is open and which drawer.
enum InspectorZone: Equatable {
    case hidden
    case shown(mode: AppModel.InspectorMode)

    var isShown: Bool { if case .shown = self { return true }; return false }
    var mode: AppModel.InspectorMode? { if case .shown(let m) = self { return m }; return nil }
}

/// One workspace view: the agent-pane tree plus its optional terminal and
/// inspector zones. A view with one leaf is an ordinary single pane; ≥2 leaves
/// is a Split View. Views are never empty — the last leaf leaving deletes it.
struct WorkspaceView: Identifiable, Equatable {
    let id: ViewID
    var agentTree: PaneNode
    var terminal: TerminalZone?
    var inspector: InspectorZone
    /// Width share of the agent zone vs. the terminal column (0.15…0.85);
    /// unused while `terminal == nil`.
    var agentAreaRatio: Double

    static func single(_ session: String, id: ViewID) -> WorkspaceView {
        WorkspaceView(id: id, agentTree: .agent(session: session),
                      terminal: nil, inspector: .hidden, agentAreaRatio: 1.0)
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
        let inspector: InspectorZone
        switch p.inspector {
        case "issues": inspector = .shown(mode: .issues)
        case "trace":  inspector = .shown(mode: .trace)
        default:       inspector = .hidden
        }
        let terminal: TerminalZone?
        if p.terminalShell != nil || p.terminalOpen == true {
            terminal = TerminalZone(shellSession: p.terminalShell)
        } else {
            terminal = nil
        }
        self.init(id: p.id,
                  agentTree: PaneNode(persisted: p.agentTree),
                  terminal: terminal,
                  inspector: inspector,
                  agentAreaRatio: p.agentAreaRatio ?? 1.0)
    }

    var persisted: PersistedWorkspaceView {
        let inspectorStr: String?
        switch inspector {
        case .hidden:         inspectorStr = nil
        case .shown(.issues): inspectorStr = "issues"
        case .shown(.trace):  inspectorStr = "trace"
        }
        return PersistedWorkspaceView(
            id: id,
            agentTree: agentTree.persisted,
            terminalShell: terminal?.shellSession,
            terminalOpen: terminal != nil ? true : nil,
            inspector: inspectorStr,
            agentAreaRatio: agentAreaRatio)
    }
}
