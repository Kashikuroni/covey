import Foundation
import CoveyKit

/// Lifecycle helpers (port of app.rs confirms_restart / the Returnable card
/// state / tmux.rs shell_single_quote).

/// The restart-all gate accepts exactly "yes" — or "да", so the confirm works
/// without leaving a Russian layout. Trimmed, case-insensitive, complete word.
func confirmsRestart(_ buffer: String) -> Bool {
    let t = buffer.trimmingCharacters(in: .whitespaces).lowercased()
    return t == "yes" || t == "да"
}

/// A worktree session whose directory vanished from disk — the worktree was
/// removed under it (promote from another session, cleanup, by hand). Checked
/// on disk, not via git==nil: a freshly created session has no git info yet.
func isReturnable(_ s: Session,
                  dirExists: (String) -> Bool = {
                      var isDir: ObjCBool = false
                      return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir)
                          && isDir.boolValue
                  }) -> Bool {
    s.worktreeRepo != nil && !dirExists(s.dir)
}

/// POSIX single-quoting: the only special character inside '' is ' itself.
func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Splits live claude sessions into restartable (idle) and kept (busy) for
/// the theme-restart offer. Missing status counts as busy — the monitor has
/// not ruled yet, and a needless restart is worse than a stale palette.
func themeRestartPlan(sessions: [Session],
                      statuses: [String: Status]) -> (idle: [String], busy: [String]) {
    var idle: [String] = [], busy: [String] = []
    for s in sessions where s.agent.split(separator: " ").first == "claude" {
        if statuses[s.name] == .idle { idle.append(s.name) }
        else { busy.append(s.name) }
    }
    return (idle, busy)
}
