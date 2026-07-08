import Foundation

/// PATH with the user-level bin directories appended when missing. Both the
/// daemon (spawned by the .app bundle) and the GUI's gh runner inherit
/// Finder's bare `/usr/bin:/bin:/usr/sbin:/sbin`, where agent binaries
/// installed under `~/.local/bin` or Homebrew don't resolve — every
/// claude/codex session (or `gh` invocation) then dies instantly with exit
/// 127. Existing entries keep their order; nothing is prepended, so system
/// binaries still win lookups.
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
