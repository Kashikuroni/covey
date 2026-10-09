/// `git status --porcelain=v2 -z` records: per-path index (x) and
/// worktree (y) states, the input of both the fingerprint and indexStatus().
public enum Porcelain {
    public struct Entry: Equatable, Sendable {
        public var x: Character          // staged state; " " when unmodified
        public var y: Character          // worktree state; " " when unmodified
        public var path: String
        public var isUntracked: Bool
    }

    /// -z records are NUL-separated: `1 XY …\0path\0`, renames carry
    /// `…\0path\0origPath\0`, untracked/ignored are `?\0path\0` / `!\0path\0`.
    public static func parse(_ output: String) -> [Entry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [Entry] = []
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch parts.first {
            case "1", "u":
                guard parts.count >= 2, i + 1 < fields.count else { return entries }
                append(&entries, xy: parts[1], path: fields[i + 1], untracked: false)
                i += 2
            case "2":
                guard parts.count >= 2, i + 2 < fields.count else { return entries }
                append(&entries, xy: parts[1], path: fields[i + 1], untracked: false)
                i += 3                       // record, path, original path
            case "?":
                guard i + 1 < fields.count else { return entries }
                append(&entries, xy: "??", path: fields[i + 1], untracked: true)
                i += 2
            default:
                i += 1                       // "!" ignored, or anything unrecognized
            }
        }
        return entries
    }

    private static func append(_ entries: inout [Entry], xy: String, path: String, untracked: Bool) {
        entries.append(Entry(x: xy.first ?? " ", y: xy.dropFirst().first ?? " ",
                             path: path, isUntracked: untracked))
    }
}
