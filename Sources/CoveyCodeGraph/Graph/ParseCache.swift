import Foundation

struct ParseKey: Hashable, Sendable {
    let path: String
    let hash: UInt64
    let length: Int

    /// FNV-1a over the UTF-8 bytes; with the length it tells versions apart.
    init(path: String, text: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        self.path = path
        self.hash = hash
        self.length = text.utf8.count
    }
}

/// Parsed files by (path, content hash). Lives as long as the review model's
/// builder, so a rebuild only parses what changed. Locked: builds may overlap.
final class ParseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ParseKey: ParsedSource] = [:]
    private var parses = 0

    func value(for key: ParseKey) -> ParsedSource? {
        lock.withLock { entries[key] }
    }

    func store(_ parsed: ParsedSource, for key: ParseKey) {
        lock.withLock {
            entries[key] = parsed
            parses += 1
        }
    }

    /// Drops every entry not in `keys` (stale versions of edited files).
    func retain(only keys: Set<ParseKey>) {
        lock.withLock { entries = entries.filter { keys.contains($0.key) } }
    }

    var count: Int { lock.withLock { entries.count } }

    /// How many times a file was parsed (cache misses), for tests.
    var parseCount: Int { lock.withLock { parses } }
}
