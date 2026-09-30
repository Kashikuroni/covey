import Foundation

/// Which side of a comparison a file is read from.
public enum SourceSide: Hashable, Sendable {
    case base, head
}

/// File access for the builder. The app implements it on top of git; tests use
/// an in-memory fake. Paths are `/`-separated, relative to the worktree root.
public protocol SourceProvider: Sendable {
    /// Every file of the side (paths from the worktree root).
    func files(_ side: SourceSide) async throws -> [String]
    /// The file's text; nil when there is no such file, or it is binary, not
    /// UTF-8, or over the size limit.
    func text(_ path: String, _ side: SourceSide) async throws -> String?
    /// Head files that contain at least one of `words` as a whole word.
    func filesMentioning(_ words: [String]) async throws -> [String]
}

/// How one file changed between base and head.
public enum ChangeKind: Hashable, Sendable {
    case added, modified, deleted
    /// Moved from `from` (its base path); `ChangedSource.path` is the new path.
    case renamed(from: String)
}

/// One changed file — the builder's input. The list must name every path
/// that differs between base and head: an unlisted file is read on the head
/// side only, whichever side is asked for.
public struct ChangedSource: Hashable, Sendable {
    /// The head path; the base path for `.deleted`.
    public var path: String
    public var change: ChangeKind

    public init(path: String, change: ChangeKind) {
        self.path = path
        self.change = change
    }

    /// Where the file is on the base side; nil for `.added`.
    public var basePath: String? {
        switch change {
        case .added: return nil
        case .modified, .deleted: return path
        case .renamed(let from): return from
        }
    }

    /// Where the file is on the head side; nil for `.deleted`.
    public var headPath: String? {
        change == .deleted ? nil : path
    }
}

/// Bounds on one build.
public struct GraphLimits: Hashable, Sendable {
    /// Wall-clock budget; past it the builder returns what it has.
    public var budget: Duration
    /// At most this many files from `filesMentioning` are parsed.
    public var maxCandidates: Int
    /// Larger files are skipped, like binary ones.
    public var maxFileBytes: Int

    public init(budget: Duration = .seconds(5), maxCandidates: Int = 2000,
                maxFileBytes: Int = 1 << 20) {
        self.budget = budget
        self.maxCandidates = maxCandidates
        self.maxFileBytes = maxFileBytes
    }

    /// 5 s, 2000 candidates, 1 MB.
    public static let standard = GraphLimits()
}

public enum LinkState: Hashable, Sendable {
    /// On both sides (or found from an unchanged file).
    case kept
    /// Only on the head side.
    case added
    /// Only on the base side.
    case removed
    /// Still written at head, but its target was deleted or renamed away.
    case broken
}

/// `from` uses `to`. Both are file paths; a deleted file keeps its base path.
public struct Link: Hashable, Sendable {
    /// The file that uses.
    public let from: String
    /// The file that is used.
    public let to: String
    /// Names used across the link (the arrow label), sorted.
    public let names: [String]
    public let state: LinkState

    public init(from: String, to: String, names: [String], state: LinkState) {
        self.from = from
        self.to = to
        self.names = names
        self.state = state
    }

    public var key: LinkKey { LinkKey(from: from, to: to) }
}

public struct LinkKey: Hashable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// One line of `path` where a link's names are used.
public struct UsageSite: Hashable, Sendable {
    public let path: String
    /// 1-based.
    public let line: Int
    /// The line without surrounding whitespace, at most `maxTextLength` characters.
    public let text: String

    public static let maxTextLength = 200

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct LinkGraph: Equatable, Sendable {
    /// Sorted by (from, to); at most one link per pair, never from == to.
    public let links: [Link]
    /// Usage sites for (from, to): lines in `from` where `names` occur,
    /// including the import line itself.
    public let usages: [LinkKey: [UsageSite]]
    /// false — the build hit the time or candidate limit.
    public let complete: Bool
    /// Why the graph is incomplete or unavailable; nil when all is well.
    public let note: String?

    public init(links: [Link], usages: [LinkKey: [UsageSite]], complete: Bool, note: String?) {
        self.links = links
        self.usages = usages
        self.complete = complete
        self.note = note
    }

    public static let empty = LinkGraph(links: [], usages: [:], complete: true, note: nil)

    public static let incompleteNote = "links incomplete"

    /// No links at all: the build failed with `reason`.
    public static func unavailable(_ reason: String) -> LinkGraph {
        LinkGraph(links: [], usages: [:], complete: false, note: "links unavailable: \(reason)")
    }
}
