import XCTest
import CoveyGit
@testable import covey

final class ReviewDiffHelpersTests: XCTestCase {
    private func line(_ kind: DiffLine.Kind, _ old: Int?, _ new: Int?, _ text: String) -> DiffLine {
        DiffLine(kind: kind, oldNumber: old, newNumber: new, text: text)
    }

    private func hunk(_ lines: [DiffLine]) -> Hunk {
        Hunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: lines)
    }

    func testContextRowsMirrorBothSides() {
        let rows = DiffSplitLayout.rows(hunk([line(.context, 1, 1, "a")]), hunkIndex: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left, rows[0].right)
        XCTAssertEqual(rows[0].id, "h0-l0")
    }

    func testChangeRunsPairRemovedWithAdded() {
        let h = hunk([
            line(.removed, 1, nil, "a"), line(.removed, 2, nil, "b"),
            line(.added, nil, 1, "A"), line(.added, nil, 2, "B"), line(.added, nil, 3, "C"),
            line(.context, 3, 4, "z"),
        ])
        let rows = DiffSplitLayout.rows(h, hunkIndex: 2)
        XCTAssertEqual(rows.map(\.left?.text), ["a", "b", nil, "z"])
        XCTAssertEqual(rows.map(\.right?.text), ["A", "B", "C", "z"])
        XCTAssertEqual(rows.map(\.id), ["h2-l0", "h2-l1", "h2-l4", "h2-l5"])
        XCTAssertEqual(DiffSplitLayout.splitRowID(h, hunkIndex: 2, lineIndex: 3), "h2-l1")
        XCTAssertEqual(DiffSplitLayout.splitRowID(h, hunkIndex: 2, lineIndex: 4), "h2-l4")
    }

    func testAddedBeforeRemovedStillPairsEveryLine() {
        let rows = DiffSplitLayout.rows(hunk([line(.added, nil, 1, "new"), line(.removed, 1, nil, "old")]),
                                        hunkIndex: 0)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap(\.left).count + rows.compactMap(\.right).count, 2)
    }

    func testStopsMarkTheStartOfEachChangeRun() {
        let first = hunk([line(.context, 1, 1, "a"), line(.removed, 2, nil, "b"), line(.added, nil, 2, "B"),
                          line(.context, 3, 3, "c"), line(.added, nil, 4, "d")])
        let second = hunk([line(.added, nil, 10, "x")])
        XCTAssertEqual(DiffSplitLayout.stops(FileDiff(hunks: [first, second], isBinary: false)),
                       [DiffStop(hunk: 0, line: 1), DiffStop(hunk: 0, line: 4), DiffStop(hunk: 1, line: 0)])
        XCTAssertEqual(DiffSplitLayout.stops(.empty), [])
    }

    func testHashFollowsContentNotLineNumbers() {
        let file = ChangedFile(path: "a", status: .modified, added: 1, removed: 0)
        let a = FileDiff(hunks: [hunk([line(.context, 1, 1, "x"), line(.added, nil, 2, "y")])], isBinary: false)
        var shifted = a
        shifted.hunks[0].lines = [line(.context, 11, 11, "x"), line(.added, nil, 12, "y")]
        var edited = a
        edited.hunks[0].lines[1].text = "Y"
        XCTAssertEqual(ReviewHash.of(a, file: file, stamp: nil), ReviewHash.of(a, file: file, stamp: nil))
        XCTAssertEqual(ReviewHash.of(a, file: file, stamp: nil), ReviewHash.of(shifted, file: file, stamp: nil))
        XCTAssertNotEqual(ReviewHash.of(a, file: file, stamp: nil), ReviewHash.of(edited, file: file, stamp: nil))
        XCTAssertEqual(ReviewHash.of(a, file: file, stamp: FileStamp(mtime: 1, size: 1)),
                       ReviewHash.of(a, file: file, stamp: FileStamp(mtime: 2, size: 1)),
                       "text diffs ignore the stamp")
    }

    func testHashOfBinaryFollowsTheStamp() {
        let file = ChangedFile(path: "b", status: .modified, added: nil, removed: nil, isBinary: true)
        let binary = FileDiff(hunks: [], isBinary: true)
        XCTAssertNotEqual(ReviewHash.of(binary, file: file, stamp: FileStamp(mtime: 1, size: 3)),
                          ReviewHash.of(binary, file: file, stamp: FileStamp(mtime: 2, size: 3)))
    }

    func testAnchorTracking() {
        let full = FileDiff(hunks: [hunk([
            line(.context, 1, 1, "import A"),
            line(.removed, 2, nil, "old()"),
            line(.added, nil, 2, "fresh()"),
            line(.context, 3, 3, "shared()"),
            line(.added, nil, 4, "moved()"),
            line(.context, 4, 5, "shared()"),
        ])], isBinary: false)
        func anchor(_ side: ReviewSide, _ n: Int, _ text: String) -> LineAnchor {
            LineAnchor(path: "f", side: side, line: n, lineText: text)
        }
        XCTAssertEqual(AnchorTracker.check(anchor(.new, 2, "fresh()"), in: full), .current)
        XCTAssertEqual(AnchorTracker.check(anchor(.new, 9, "moved()"), in: full), .moved(to: 4))
        XCTAssertEqual(AnchorTracker.check(anchor(.new, 9, "shared()"), in: full), .outdated, "ambiguous")
        XCTAssertEqual(AnchorTracker.check(anchor(.new, 2, "gone()"), in: full), .outdated)
        XCTAssertEqual(AnchorTracker.check(anchor(.old, 2, "old()"), in: full), .current)
        XCTAssertEqual(AnchorTracker.check(anchor(.new, 1, "import A"), in: nil), .fileGone)
    }
}
