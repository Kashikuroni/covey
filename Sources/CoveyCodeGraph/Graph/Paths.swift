import Foundation

/// `/`-separated repository paths; `""` is the repository root.
enum Paths {
    static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func join(_ dir: String, _ rel: String) -> String {
        if dir.isEmpty { return rel }
        if rel.isEmpty { return dir }
        return dir + "/" + rel
    }

    /// `rel` resolved against `dir`, with `.` and `..` folded; nil when it
    /// climbs above the root.
    static func normalize(_ dir: String, _ rel: String) -> String? {
        var parts: [Substring] = []
        for part in (join(dir, rel)).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// True when `path` lies inside `dir` (the root contains everything).
    static func contains(_ dir: String, _ path: String) -> Bool {
        dir.isEmpty || path.hasPrefix(dir + "/")
    }
}
