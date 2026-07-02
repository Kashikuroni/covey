import XCTest
@testable import covey

final class NoteModelTests: XCTestCase {
    let sample = """
    # Plan
    - [ ] first
    - [x] second
    - not a task
    * bullet
    plain text

      - [X] indented done
    """

    func testParseTaskStrictness() {
        XCTAssertEqual(parseTask("- [ ] open")?.done, false)
        XCTAssertEqual(parseTask("- [x] closed")?.done, true)
        XCTAssertEqual(parseTask("  - [X] caps")?.text, "caps")
        XCTAssertNil(parseTask("-[ ] no space"))
        XCTAssertNil(parseTask("- [y] wrong mark"))
        XCTAssertNil(parseTask("text with [ ] inside"))
    }

    func testParseNoteLines() {
        let lines = parseNote(sample)
        XCTAssertEqual(lines[0], .heading(level: 1, text: "Plan"))
        XCTAssertEqual(lines[1], .task(done: false, text: "first"))
        XCTAssertEqual(lines[2], .task(done: true, text: "second"))
        XCTAssertEqual(lines[3], .bullet("not a task"))
        XCTAssertEqual(lines[4], .bullet("bullet"))
        XCTAssertEqual(lines[5], .text("plain text"))
        XCTAssertEqual(lines[6], .blank)
        XCTAssertEqual(lines[7], .task(done: true, text: "indented done"))
        XCTAssertEqual(parseNote("####### seven"), [.heading(level: 6, text: "seven")])
    }

    func testCountsAndIndices() {
        let c = taskCounts(sample)
        XCTAssertEqual(c.done, 2)
        XCTAssertEqual(c.total, 3)
        XCTAssertEqual(taskLineIndices(sample), [1, 2, 7])
    }

    func testToggleKeepsIndentAndText() {
        let toggled = toggleTask(sample, ordinal: 0)
        XCTAssertTrue(toggled.contains("- [x] first"))
        let back = toggleTask(toggled, ordinal: 0)
        XCTAssertEqual(back, sample)
        let indented = toggleTask(sample, ordinal: 2)
        XCTAssertTrue(indented.contains("  - [ ] indented done"), "indent preserved")
        XCTAssertEqual(toggleTask(sample, ordinal: 99), sample, "out of range no-op")
    }

    func testRemoveTasks() {
        let removed = removeTasks(sample, ordinals: [0, 2])
        XCTAssertFalse(removed.contains("first"))
        XCTAssertFalse(removed.contains("indented"))
        XCTAssertTrue(removed.contains("- [x] second"))
        XCTAssertTrue(removed.contains("# Plan"), "non-task lines untouched")
    }

    func testSelectedAsNumbered() {
        XCTAssertEqual(selectedAsNumbered(sample, ordinals: [2, 0]),
                       "1. indented done\n2. first")
        XCTAssertEqual(selectedAsNumbered(sample, ordinals: [99]), "")
    }
}
