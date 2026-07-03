import CoveyKit

/// Project-identity helpers (port of app.rs session_root/project_root):
/// sessions sharing a root are one project in the list, notes and renames.

/// The project root for a session directory: the path with any trailing
/// `/.worktrees/<branch>...` segment stripped.
func projectRoot(_ dir: String) -> String {
    var trimmed = dir
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    if let range = trimmed.range(of: "/.worktrees/") {
        return String(trimmed[..<range.lowerBound])
    }
    if trimmed.hasSuffix("/.worktrees") {
        return String(trimmed.dropLast("/.worktrees".count))
    }
    return trimmed
}

/// Default display name for a project: the last path component of its root.
func projectDefaultName(_ root: String) -> String {
    var trimmed = root
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
}

/// The project root for a session: the worktree's repo root if this is a
/// worktree session, otherwise its directory with the `.worktrees/…` suffix
/// stripped (covers sessions predating the worktreeRepo field).
func sessionRoot(_ s: Session) -> String {
    guard var repo = s.worktreeRepo, !repo.isEmpty else { return projectRoot(s.dir) }
    while repo.count > 1 && repo.hasSuffix("/") { repo.removeLast() }
    return repo
}
