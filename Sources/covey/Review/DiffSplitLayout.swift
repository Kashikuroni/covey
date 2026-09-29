import Foundation
import CoveyGit

/// One side-by-side row: a removed line paired with an added one, or a
/// context line on both sides. Indexes point into `Hunk.lines`.
struct SplitRow: Identifiable, Equatable {
    let id: String
    let left: DiffLine?
    let right: DiffLine?
    let leftIndex: Int?
    let rightIndex: Int?
}

/// The first line of a run of changed lines — what `[` / `]` step through.
struct DiffStop: Equatable {
    let hunk: Int
    let line: Int
}

enum DiffSplitLayout {
    /// Row id shared by both layouts: unified rows use their own line index,
    /// split rows the index of their left line (or right, when left is empty).
    static func rowID(hunk: Int, line: Int) -> String { "h\(hunk)-l\(line)" }

    static func rows(_ hunk: Hunk, hunkIndex: Int) -> [SplitRow] {
        let lines = hunk.lines
        var rows: [SplitRow] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .context {
                rows.append(SplitRow(id: rowID(hunk: hunkIndex, line: i), left: lines[i], right: lines[i],
                                     leftIndex: i, rightIndex: i))
                i += 1
                continue
            }
            var removed: [Int] = []
            var added: [Int] = []
            while i < lines.count, lines[i].kind == .removed { removed.append(i); i += 1 }
            while i < lines.count, lines[i].kind == .added { added.append(i); i += 1 }
            for j in 0..<max(removed.count, added.count) {
                let l = j < removed.count ? removed[j] : nil
                let r = j < added.count ? added[j] : nil
                rows.append(SplitRow(id: rowID(hunk: hunkIndex, line: l ?? r!),
                                     left: l.map { lines[$0] }, right: r.map { lines[$0] },
                                     leftIndex: l, rightIndex: r))
            }
        }
        return rows
    }

    /// The split row that shows line `lineIndex` of `hunk`.
    static func splitRowID(_ hunk: Hunk, hunkIndex: Int, lineIndex: Int) -> String? {
        rows(hunk, hunkIndex: hunkIndex)
            .first { $0.leftIndex == lineIndex || $0.rightIndex == lineIndex }?.id
    }

    static func stops(_ diff: FileDiff) -> [DiffStop] {
        var stops: [DiffStop] = []
        for (h, hunk) in diff.hunks.enumerated() {
            for (i, line) in hunk.lines.enumerated() where line.kind != .context {
                if i == 0 || hunk.lines[i - 1].kind == .context {
                    stops.append(DiffStop(hunk: h, line: i))
                }
            }
        }
        return stops
    }
}
