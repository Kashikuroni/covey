import Foundation

/// What a review compares: `base` (a ref name, re-resolved on every load)
/// against the working tree or another ref, through their merge-base.
public struct GitComparison: Hashable, Codable, Sendable {
    public enum Head: Hashable, Codable, Sendable {
        case workingTree
        case ref(String)
    }

    public var base: String
    public var head: Head

    public init(base: String, head: Head = .workingTree) {
        self.base = base
        self.head = head
    }

    /// Stable text identity for storage keys.
    public var storageKey: String {
        switch head {
        case .workingTree: return "\(base)\u{0}wt"
        case .ref(let ref): return "\(base)\u{0}ref:\(ref)"
        }
    }

    /// `main…working tree`, `main…feat/x`.
    public var label: String {
        switch head {
        case .workingTree: return "\(base)…working tree"
        case .ref(let ref): return "\(base)…\(ref)"
        }
    }
}

/// Modification time and size of a working-tree file, for cheap change checks.
public struct FileStamp: Hashable, Codable, Sendable {
    public var mtime: Double
    public var size: Int64

    public init(mtime: Double, size: Int64) {
        self.mtime = mtime
        self.size = size
    }
}

/// One read of a comparison.
public struct ComparisonState: Equatable, Sendable {
    public var mergeBase: String
    /// Sorted by path.
    public var files: [ChangedFile]
    /// Working-tree comparisons only; empty for ref…ref.
    public var stamps: [String: FileStamp]
    public var fingerprint: String

    public init(mergeBase: String, files: [ChangedFile], stamps: [String: FileStamp],
                fingerprint: String) {
        self.mergeBase = mergeBase
        self.files = files
        self.stamps = stamps
        self.fingerprint = fingerprint
    }
}
