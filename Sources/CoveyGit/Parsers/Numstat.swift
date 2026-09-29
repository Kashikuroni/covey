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
