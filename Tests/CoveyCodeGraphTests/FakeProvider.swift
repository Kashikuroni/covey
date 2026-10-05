import Foundation
@testable import CoveyCodeGraph

struct FakeError: Error, CustomStringConvertible {
    let description: String
}

/// An in-memory repository: two sides of path → text. Reads are logged so
/// tests can see what the builder asked for.
final class FakeProvider: SourceProvider, @unchecked Sendable {
    let base: [String: String]
    let head: [String: String]
    /// Thrown by every call when set.
    var failure: FakeError?
    /// Slept before every `text` call.
    var readDelay: Duration?
    private let lock = NSLock()
    private var reads: [(String, SourceSide)] = []

    /// `common` files are on both sides with the same text.
    init(common: [String: String] = [:], base: [String: String] = [:], head: [String: String] = [:]) {
        self.base = common.merging(base) { _, new in new }
        self.head = common.merging(head) { _, new in new }
    }

    func files(_ side: SourceSide) async throws -> [String] {
        if let failure { throw failure }
        return (side == .base ? base : head).keys.sorted()
    }

    func text(_ path: String, _ side: SourceSide) async throws -> String? {
        if let failure { throw failure }
        if let readDelay { try await Task.sleep(for: readDelay) }
        lock.withLock { reads.append((path, side)) }
        return (side == .base ? base : head)[path]
    }

    func filesMentioning(_ words: [String]) async throws -> [String] {
        if let failure { throw failure }
        return head.keys.sorted().filter { path in
            words.contains { FakeProvider.mentions(head[path]!, $0) }
        }
    }

    /// Paths read on `side`, in order.
    func readPaths(_ side: SourceSide) -> [String] {
        lock.withLock { reads.filter { $0.1 == side }.map(\.0) }
    }

    /// Every difference between the sides; `renames` maps old → new path.
    func changes(renames: [String: String] = [:]) -> [ChangedSource] {
        var out: [ChangedSource] = []
        let renamedTo = Set(renames.values)
        for (old, new) in renames { out.append(ChangedSource(path: new, change: .renamed(from: old))) }
        for path in Set(base.keys).union(head.keys) where renames[path] == nil && !renamedTo.contains(path) {
            switch (base[path], head[path]) {
            case (nil, _?): out.append(ChangedSource(path: path, change: .added))
            case (_?, nil): out.append(ChangedSource(path: path, change: .deleted))
            case let (b?, h?) where b != h: out.append(ChangedSource(path: path, change: .modified))
            default: break
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `git grep -w` semantics: the match is not preceded or followed by a
    /// word character (letter, digit, underscore).
    static func mentions(_ text: String, _ word: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c == "_" || c.isLetter || c.isNumber
    }
}
