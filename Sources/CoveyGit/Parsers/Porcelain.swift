/// `git status --porcelain=v2 -z` records: per-path index (x) and
/// worktree (y) states, the input of both the fingerprint and indexStatus().
public enum Porcelain {
    public struct Entry: Equatable, Sendable {
        public var x: Character          // staged state; " " when unmodified
        public var y: Character          // worktree state; " " when unmodified
        public var path: String
        public var isUntracked: Bool
    }

    /// One NUL-terminated field per record. Changed records keep the path in
    /// the same field as the header (`1 XY sub mH mI mW hH hI <path>`), so the
    /// path is the tail after a bounded split; renames carry the original path
    /// in a second field (`2 … <X><score> <path>\0<origPath>\0`); untracked
    /// and ignored are single fields — `? <path>\0` / `! <path>\0`.
    public static func parse(_ output: String) -> [Entry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [Entry] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            switch field.first {
            case "?":
                entries.append(Entry(x: "?", y: "?",
                                     path: String(field.dropFirst(2)), isUntracked: true))
                i += 1
            case "2":
                let parts = field.split(separator: " ", maxSplits: 9,
                                        omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 10, i + 1 < fields.count else { return entries }
                append(&entries, xy: parts[1], path: parts[9], untracked: false)
                i += 2                           // record+path, then the original path
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8,
                                        omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 9 else { return entries }
                append(&entries, xy: parts[1], path: parts[8], untracked: false)
                i += 1
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10,
                                        omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 11 else { return entries }
                append(&entries, xy: parts[1], path: parts[10], untracked: false)
                i += 1
            default:
                i += 1                           // "!" ignored, or anything unrecognized
            }
        }
        return entries
    }

    private static func append(_ entries: inout [Entry], xy: String, path: String, untracked: Bool) {
        entries.append(Entry(x: xy.first ?? " ", y: xy.dropFirst().first ?? " ",
                             path: path, isUntracked: untracked))
    }
}
