import XCTest
@testable import CoveyGit

final class PorcelainTests: XCTestCase {
    private static let h1 = "5626abf0f72e58d7a153368ba57db4c673c0e171"

    func testChangedRecordSplitsXYAndPath() throws {
        // Real -z shape: the path rides in the same NUL field as the header.
        let output = "1 .M N... 100644 100644 100644 \(Self.h1) \(Self.h1) src/a.swift\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.x, ".")
        XCTAssertEqual(entry.y, "M")
        XCTAssertEqual(entry.path, "src/a.swift")
        XCTAssertFalse(entry.isUntracked)
    }

    func testRenameRecordTakesNewPathAndSkipsOriginal() throws {
        let output = "2 R. N... 100644 100644 100644 \(Self.h1) \(Self.h1) R100 new.txt\0old.txt\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.path, "new.txt")
        XCTAssertEqual(entry.x, "R")
    }

    func testUntrackedAndIgnoredRecords() {
        // Real git -z emits `? <path>` as ONE NUL-terminated field.
        let output = "? notes.md\0! build.log\0"
        let entries = Porcelain.parse(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isUntracked)
        XCTAssertEqual(entries[0].path, "notes.md")
    }

    func testPathWithSpacesSurvivesTheBoundedSplit() throws {
        let output = "? new dir/ünï code.txt\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.path, "new dir/ünï code.txt")
    }

    func testBothIndexAndWorktreeDirtyReadAsStaged() throws {
        // Review Focus 4: staged modification edited again → X='M', Y='M'.
        let output = "1 MM N... 100644 100644 100644 \(Self.h1) \(Self.h1) a.txt\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.x, "M")
        XCTAssertEqual(entry.y, "M")
    }

    func testUntrackedAfterChangedRecordDoesNotTruncate() throws {
        let output = "1 .M N... 100644 100644 100644 \(Self.h1) \(Self.h1) a.txt\0"
            + "? new dir/ünï code.txt\0"
        let entries = Porcelain.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "a.txt")
        XCTAssertEqual(entries[1].path, "new dir/ünï code.txt")
        XCTAssertTrue(entries[1].isUntracked)
    }

    func testEmptyOutputParsesToEmpty() {
        XCTAssertEqual(Porcelain.parse(""), [])
    }
}
