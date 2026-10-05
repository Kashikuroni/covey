import XCTest
@testable import CoveyGit

final class ParserTests: XCTestCase {
    func testNameStatusParsesPlainRenameAndCopyRecords() {
        let out = "M\0src/a b.swift\0R087\0old/x.swift\0new/x.swift\0A\0ünï.txt\0D\0gone.txt\0C100\0t.txt\0t copy.txt\0T\0link\0"
        let entries = NameStatus.parse(out)
        XCTAssertEqual(entries.map(\.path), ["src/a b.swift", "new/x.swift", "ünï.txt", "gone.txt", "t copy.txt", "link"])
        XCTAssertEqual(entries[1].oldPath, "old/x.swift")
        XCTAssertEqual(entries.map { NameStatus.status(for: $0.code) },
                       [.modified, .renamed, .added, .deleted, .added, .modified])
    }

    func testNameStatusIgnoresEmptyAndTruncatedOutput() {
        XCTAssertEqual(NameStatus.parse("").count, 0)
        XCTAssertEqual(NameStatus.parse("R100\0only-old\0").count, 0)
    }

    func testNumstatByPathKeysRenamesByNewPathAndMarksBinary() {
        let out = "1\t2\tfile.swift\0-\t-\tbinary.dat\0003\t0\t\0old.txt\0new.txt\0"
        let map = Numstat.byPath(out)
        XCTAssertEqual(map["file.swift"], LineCounts(added: 1, removed: 2))
        XCTAssertEqual(map["binary.dat"], LineCounts(added: nil, removed: nil))
        XCTAssertEqual(map["new.txt"], LineCounts(added: 3, removed: 0))
        XCTAssertNil(map["old.txt"])
    }

    func testUnifiedDiffNumbersBothSides() {
        let text = """
        diff --git a/f.txt b/f.txt
        index 1..2 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@ func top()
         one
        -two
        +2
         three
        +four
        """
        let diff = UnifiedDiff.parse(text)
        XCTAssertFalse(diff.isBinary)
        XCTAssertEqual(diff.hunks.count, 1)
        let hunk = diff.hunks[0]
        XCTAssertEqual(hunk.header, "@@ -1,3 +1,4 @@ func top()")
        XCTAssertEqual([hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount], [1, 3, 1, 4])
        XCTAssertEqual(hunk.lines, [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one"),
            DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "two"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "2"),
            DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "three"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 4, text: "four"),
        ])
        XCTAssertEqual(diff.lineCount, 5)
    }

    func testUnifiedDiffHandlesSingleLineHunksNoNewlineMarkerAndContentThatLooksLikeHeaders() {
        let text = "@@ -1 +1 @@\n--- not a header\n+++ also content\n\\ No newline at end of file\n@@ -10,0 +11,2 @@\n+a\n+\n"
        let diff = UnifiedDiff.parse(text)
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks[0].lines.map(\.kind), [.removed, .added])
        XCTAssertEqual(diff.hunks[0].lines.map(\.text), ["-- not a header", "++ also content"])
        XCTAssertEqual([diff.hunks[0].oldCount, diff.hunks[0].newCount], [1, 1])
        XCTAssertEqual(diff.hunks[1].lines.map(\.newNumber), [11, 12])
        XCTAssertEqual(diff.hunks[1].lines[1].text, "")
    }

    func testBinaryDiffIsFlagged() {
        let diff = UnifiedDiff.parse("diff --git a/b.dat b/b.dat\nindex 1..2\nBinary files a/b.dat and b/b.dat differ\n")
        XCTAssertTrue(diff.isBinary)
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testModeOnlyDiffHasNoHunksAndIsNotBinary() {
        let diff = UnifiedDiff.parse("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        XCTAssertFalse(diff.isBinary)
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testEmptyInputIsEmptyDiff() {
        XCTAssertEqual(UnifiedDiff.parse(""), .empty)
    }

    func testCRLFLinesSplitCorrectly() {
        let text = "@@ -1,2 +1,2 @@\n one\r\n-two\r\n+2\r\n"
        let diff = UnifiedDiff.parse(text)
        XCTAssertEqual(diff.hunks.count, 1)
        let hunk = diff.hunks[0]
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0], DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one"))
        XCTAssertEqual(hunk.lines[1], DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "two"))
        XCTAssertEqual(hunk.lines[2], DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "2"))
    }

    func testCRLFWithNoNewlineMarker() {
        let text = "@@ -1 +1 @@\n-a\r\n+b\r\n\\ No newline at end of file\n"
        let diff = UnifiedDiff.parse(text)
        XCTAssertEqual(diff.hunks.count, 1)
        let hunk = diff.hunks[0]
        XCTAssertEqual(hunk.lines.count, 2)
        XCTAssertEqual(hunk.lines[0].text, "a")
        XCTAssertEqual(hunk.lines[1].text, "b")
    }

    func testCombiningMarksPreserved() {
        let text = "@@ -1,2 +1,2 @@\n-a\n+\u{301}b\n \u{200D}c\n"
        let diff = UnifiedDiff.parse(text)
        XCTAssertEqual(diff.hunks.count, 1)
        let hunk = diff.hunks[0]
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0].text, "a")
        XCTAssertEqual(hunk.lines[1].text, "\u{301}b")
        XCTAssertEqual(hunk.lines[2].text, "\u{200D}c")
        XCTAssertEqual(hunk.lines.map(\.newNumber), [nil, 1, 2])
    }

    /// `diff.suppressBlankEmpty=true` prints a blank context line as a bare "\n".
    func testBareEmptyLineInsideHunkIsBlankContextAndKeepsNumbering() {
        let diff = UnifiedDiff.parse("@@ -1,4 +1,4 @@\n one\n\n-three\n+THREE\n four\n")
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].lines, [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one"),
            DiffLine(kind: .context, oldNumber: 2, newNumber: 2, text: ""),
            DiffLine(kind: .removed, oldNumber: 3, newNumber: nil, text: "three"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 3, text: "THREE"),
            DiffLine(kind: .context, oldNumber: 4, newNumber: 4, text: "four"),
        ])
    }

    /// The empty piece after the final newline is a split artefact, not a line.
    func testTrailingNewlineAddsNoLineOnceCountsAreExhausted() {
        let plain = UnifiedDiff.parse("@@ -1,2 +1,2 @@\n one\n four\n")
        XCTAssertEqual(plain.hunks[0].lines.count, 2)
        let suppressed = UnifiedDiff.parse("@@ -1,3 +1,3 @@\n one\n\n four\n\n")
        XCTAssertEqual(suppressed.hunks[0].lines.map(\.text), ["one", "", "four"])
        XCTAssertEqual(suppressed.hunks[0].lines.map(\.newNumber), [1, 2, 3])
    }
}
