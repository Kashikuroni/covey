import CoveyKit

/// Project-identity helpers (port of app.rs session_root/project_root):
/// sessions sharing a root are one project in the list and renames.
/// Реализация переехала в CoveyKit (PM Foundation: атрибуция нужна и демону);
/// здесь — форвардеры, чтобы места использования в GUI не менялись.

/// The project root for a session directory: the path with any trailing
/// `/.worktrees/<branch>...` segment stripped.
func projectRoot(_ dir: String) -> String { pmProjectRoot(dir) }

/// Default display name for a project: the last path component of its root.
func projectDefaultName(_ root: String) -> String { pmProjectDefaultName(root) }

/// The project root for a session: the worktree's repo root if this is a
/// worktree session, otherwise its directory with the `.worktrees/…` suffix
/// stripped (covers sessions predating the worktreeRepo field).
func sessionRoot(_ s: Session) -> String { pmSessionRoot(s) }

/// Agent-name → project identity for the forecast agents table: a path
/// (external agents carry `~/…`/absolute cwd) resolves to the same project
/// name the session list shows — user rename or the root's last component —
/// plus the worktree branch tail. Anything else (Covey session names,
/// `ext:` fallbacks) is not a path: nil keeps the existing display.
enum AgentNaming {
    static func projectParts(raw: String, home: String,
                             displayName: (String) -> String) -> (project: String, branch: String?)? {
        var path = raw
        if path == "~" { return nil }
        if path.hasPrefix("~") { path = home + path.dropFirst() }
        guard path.hasPrefix("/") else { return nil }
        let root = projectRoot(path)
        let branch = path.range(of: "/.worktrees/").map { String(path[$0.upperBound...]) }
        return (displayName(root), branch)
    }
}
