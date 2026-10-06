import Foundation

/// Pure directory-picker logic for the new-session form (port of
/// amux-core browse.rs): path splitting and the live subdir listing.
enum DirBrowse {
    /// Upper bound on listed entries so the picker stays responsive in huge
    /// directories (it re-runs per keystroke).
    static let maxList = 200

    /// Splits into (directory part including the trailing slash, trailing
    /// segment). No '/' present → ("", text).
    static func splitPath(_ text: String) -> (base: String, filter: String) {
        guard let idx = text.lastIndex(of: "/") else { return ("", text) }
        let after = text.index(after: idx)
        return (String(text[...idx]), String(text[after...]))
    }

    /// Subdirectories of `base` whose names match `filter` (case-insensitive
    /// prefix). Hidden dirs show only when the filter itself starts with '.'.
    /// Sorted case-insensitively, capped at `maxList` — each entry's name is
    /// checked before its type so giant directories stay cheap.
    static func list(base: String, filter: String) -> [String] {
        let lower = filter.lowercased()
        let showHidden = filter.hasPrefix(".")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base)
        else { return [] }
        var out: [String] = []
        for name in entries {
            if !showHidden && name.hasPrefix(".") { continue }
            if !lower.isEmpty && !name.lowercased().hasPrefix(lower) { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base + "/" + name, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            out.append(name)
            if out.count >= maxList { break }
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// The visible field chain of the new-session form (port of the TUI's
/// `field_sequence`): drives Enter-advance and focus.
enum FormField: Hashable {
    case name, dir, worktree, branch, base, agent, customAgent
}

func formFieldSequence(isRepo: Bool, showWorktreeToggle: Bool,
                       showBase: Bool, customAgent: Bool) -> [FormField] {
    var fields: [FormField] = [.name, .dir]
    if isRepo {
        fields.append(.branch)
        if showWorktreeToggle { fields.append(.worktree) }
        if showBase { fields.append(.base) }
    }
    fields.append(.agent)
    if customAgent { fields.append(.customAgent) }
    return fields
}
