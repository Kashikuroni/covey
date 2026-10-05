import Foundation

public enum NameStatus {
    public struct Entry: Equatable, Sendable {
        public var code: Character
        public var path: String
        public var oldPath: String?
    }

    /// `--name-status -z`: `X\0path\0`; renames and copies carry a score and
    /// two paths: `R087\0old\0new\0`.
    public static func parse(_ output: String) -> [Entry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [Entry] = []
        var i = 0
        while i < fields.count {
            guard let code = fields[i].first else { i += 1; continue }
            if code == "R" || code == "C" {
                guard i + 2 < fields.count, !fields[i + 2].isEmpty else { break }
                entries.append(Entry(code: code, path: fields[i + 2], oldPath: fields[i + 1]))
                i += 3
            } else {
                guard i + 1 < fields.count else { break }
                entries.append(Entry(code: code, path: fields[i + 1], oldPath: nil))
                i += 2
            }
        }
        return entries
    }

    /// Copies read as additions and type changes as modifications.
    public static func status(for code: Character) -> FileStatus {
        switch code {
        case "A", "C": return .added
        case "D": return .deleted
        case "R": return .renamed
        default: return .modified
        }
    }
}
