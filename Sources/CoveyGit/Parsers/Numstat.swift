import Foundation

public enum Numstat {
    /// Totals of a `--numstat -z` listing. Binary records (`-\t-`) count as a
    /// file with no lines; rename records (`a\tr\t\0old\0new\0`) count once.
    /// Sums saturate at `UInt32.max`.
    public static func totals(_ output: String) -> DiffTotals {
        let limit = UInt64(UInt32.max)
        var files: UInt64 = 0
        var added: UInt64 = 0
        var removed: UInt64 = 0

        func add(_ value: UInt64, to total: inout UInt64) {
            total += min(value, limit - total)
        }

        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\t", maxSplits: 2,
                                      omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            add(1, to: &files)
            if let count = UInt64(fields[0]) { add(count, to: &added) }
            if let count = UInt64(fields[1]) { add(count, to: &removed) }
        }
        return DiffTotals(files: UInt32(files), added: UInt32(added), removed: UInt32(removed))
    }
}

/// Line counts of one numstat record; both nil for a binary file.
public struct LineCounts: Equatable, Sendable {
    public var added: Int?
    public var removed: Int?

    public init(added: Int?, removed: Int?) {
        self.added = added
        self.removed = removed
    }
}

extension Numstat {
    /// `--numstat -z` records keyed by the (new) path: `a\tr\tpath\0`, and for
    /// renames `a\tr\t\0old\0new\0`.
    public static func byPath(_ output: String) -> [String: LineCounts] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var map: [String: LineCounts] = [:]
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { i += 1; continue }
            let counts = LineCounts(added: Int(parts[0]), removed: Int(parts[1]))
            if parts[2].isEmpty {
                guard i + 2 < fields.count else { break }
                map[fields[i + 2]] = counts
                i += 3
            } else {
                map[String(parts[2])] = counts
                i += 1
            }
        }
        return map
    }
}
