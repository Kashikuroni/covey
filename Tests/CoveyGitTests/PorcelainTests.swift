import XCTest
@testable import CoveyGit

final class PorcelainTests: XCTestCase {
    func testChangedRecordSplitsXYAndPath() throws {
        let output = "1 M. ... 000000 111111 222222 h1 h2\0src/a.swift\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.x, "M")
        XCTAssertEqual(entry.y, ".")
        XCTAssertEqual(entry.path, "src/a.swift")
        XCTAssertFalse(entry.isUntracked)
    }

    func testRenameRecordTakesNewPathAndSkipsOriginal() throws {
        let output = "2 R. ... 000000 111111 222222 h1 h2 R100\0new.txt\0old.txt\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.path, "new.txt")
        XCTAssertEqual(entry.x, "R")
    }

    func testUntrackedAndIgnoredRecords() {
        let output = "?\0notes.md\0!\0build.log\0"
        let entries = Porcelain.parse(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isUntracked)
        XCTAssertEqual(entries[0].path, "notes.md")
    }

    func testBothIndexAndWorktreeDirtyReadAsStaged() throws {
        // Review Focus 4: staged modification edited again → X='M', Y='M'.
        let output = "1 MM ... 000000 111111 222222 h1 h2\0a.txt\0"
        let entry = try XCTUnwrap(Porcelain.parse(output).first)
        XCTAssertEqual(entry.x, "M")
        XCTAssertEqual(entry.y, "M")
    }

    func testEmptyOutputParsesToEmpty() {
        XCTAssertEqual(Porcelain.parse(""), [])
    }
}
