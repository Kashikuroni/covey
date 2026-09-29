import Foundation

public enum FileStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case added = "A", modified = "M", deleted = "D", renamed = "R"
}

/// One path in a comparison.
public struct ChangedFile: Hashable, Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    /// The pre-rename path for `.renamed`.
    public var oldPath: String?
    public var status: FileStatus
    /// nil when git reports no line counts: binary, or an untracked file over
    /// the counting size cap.
    public var added: Int?
    public var removed: Int?
    public var isBinary: Bool
    /// Not in the index: shown as added, diffed against /dev/null.
    public var isUntracked: Bool

    public init(path: String, oldPath: String? = nil, status: FileStatus,
                added: Int?, removed: Int?, isBinary: Bool = false, isUntracked: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
        self.isUntracked = isUntracked
    }
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, added, removed }
    public var kind: Kind
    /// Line number on the old side; nil for added lines.
    public var oldNumber: Int?
    /// Line number on the new side; nil for removed lines.
    public var newNumber: Int?
    /// The line without its `+`/`-`/space prefix.
    public var text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct Hunk: Hashable, Sendable {
    /// The full `@@ -a,b +c,d @@ context` line.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Hashable, Sendable {
    public var hunks: [Hunk]
    public var isBinary: Bool

    public init(hunks: [Hunk], isBinary: Bool) {
        self.hunks = hunks
        self.isBinary = isBinary
    }

    public static let empty = FileDiff(hunks: [], isBinary: false)

    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}
