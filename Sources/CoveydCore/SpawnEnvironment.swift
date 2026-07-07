import Foundation

/// PATH with the user-level bin directories appended when missing. A daemon
/// spawned by the .app bundle inherits Finder's bare
/// `/usr/bin:/bin:/usr/sbin:/sbin`, where agent binaries installed under
/// `~/.local/bin` or Homebrew don't resolve — every claude/codex session
/// then dies instantly with exit 127. Existing entries keep their order;
/// nothing is prepended, so system binaries still win lookups.
/// Terminal-capability variables the session children need but a
/// Finder-spawned daemon lacks. The GUI renders through SwiftTerm, which
/// speaks truecolor xterm — without these, TUIs probe a dumb terminal and
/// fall back to monochrome ASCII. Existing values are never overridden.
/// Deliberately NOT setting CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN: inline
/// claude was tried (smooth viewport scrolling of the chat) and reverted —
/// on every pane resize the normal-buffer transcript reflows into mush and
/// ink's redraw leaves duplicate blocks in the scrollback.
public func terminalEnvDefaults(
    _ current: [String: String]
) -> [(key: String, value: String)] {
    [("TERM", "xterm-256color"),
     ("COLORTERM", "truecolor"),
     ("LANG", "en_US.UTF-8")].filter { current[$0.0] == nil }
}

public func enrichedPATH(_ current: String?, home: String) -> String {
    let base = current ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    var entries = base.split(separator: ":").map(String.init)
    let present = Set(entries)
    for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    where !present.contains(dir) {
        entries.append(dir)
    }
    return entries.joined(separator: ":")
}
