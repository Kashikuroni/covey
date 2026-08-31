import XCTest
@testable import covey

final class LogSearchTests: XCTestCase {
    private let usage = """
    {"e":"start"}
    {"e":"claude","err":"no auth"}
    {"e":"codex","ev":"exit"}
    {"e":"note","msg":"regex( is literal here"}
    """
    private let layout = """
    {"e":"layout","name":"agent"}
    {"e":"unmount"}
    """

    private var files: [(name: String, content: String)] {
        [("usage.log", usage), ("pane-layout.log", layout)]
    }

    // MARK: file discovery

    func testLogFilesSortedByModificationNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.log")
        let new = dir.appendingPathComponent("new.log")
        let ignored = dir.appendingPathComponent("notes.txt")
        try "a".write(to: old, atomically: true, encoding: .utf8)
        try "b".write(to: ignored, atomically: true, encoding: .utf8)
        try "c".write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: old.path)

        XCTAssertEqual(logFiles(in: dir.path), [new.path, old.path])
    }

    func testLogFilesMissingDirectoryIsEmpty() {
        XCTAssertEqual(logFiles(in: "/nonexistent/usage-logs"), [])
    }

    // MARK: matching

    func testRegexQueryMatchesAcrossFilesNewestFirst() {
        let hits = searchLogs(files: files, query: "exit|unmount")
        XCTAssertEqual(hits.map(\.text), [
            "{\"e\":\"codex\",\"ev\":\"exit\"}",      // usage.log, bottom-up
            "{\"e\":\"unmount\"}",                    // pane-layout.log, bottom-up
        ])
        XCTAssertEqual(hits.map(\.file), ["usage.log", "pane-layout.log"])
    }

    func testResultsCarryOneBasedOriginalLineNumbers() {
        let hits = searchLogs(files: files, query: "no auth")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].line, 2)
    }

    func testInvalidRegexFallsBackToLiteralCaseInsensitive() {
        // "msg":"regex( is not a valid regex; the literal text does exist.
        let hits = searchLogs(files: files, query: "MSG\":\"REGEX(")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].line, 4)
    }

    func testLiteralFallbackDoesNotIgnoreMetacharacters() {
        // The literal "no auth(" appears nowhere, so nothing matches —
        // the fallback escapes the query rather than dropping metachars.
        XCTAssertEqual(searchLogs(files: files, query: "NO AUTH(").count, 0)
    }

    func testLiteralFallbackIsCaseInsensitive() {
        XCTAssertEqual(searchLogs(files: files, query: "No Auth").count, 1)
    }

    func testEmptyQueryReturnsTailOfEachFileNewestFirst() {
        let hits = searchLogs(files: files, query: "")
        XCTAssertEqual(hits.first?.file, "usage.log")       // newest file first…
        XCTAssertEqual(hits.first?.line, 4)                 // …its newest line first
        XCTAssertEqual(hits.last?.file, "pane-layout.log")  // oldest file last
        XCTAssertEqual(hits.last?.line, 1)                  // reading bottom-up
    }

    func testEmptyQueryTailIsCappedPerFile() {
        let big = (1...1000).map { "row \($0)" }.joined(separator: "\n")
        let hits = searchLogs(files: [("big.log", big)], query: "")
        XCTAssertEqual(hits.count, 100)   // emptyQueryTail
        XCTAssertEqual(hits.first?.text, "row 1000")
    }

    // MARK: limit

    func testLimitCapsResultsKeepingNewest() {
        let big = (1...1000).map { "row \($0)" }.joined(separator: "\n")
        let hits = searchLogs(files: [("big.log", big)], query: "row", limit: 10)
        XCTAssertEqual(hits.count, 10)
        XCTAssertEqual(hits.first?.text, "row 1000")   // newest (bottom) kept
        XCTAssertEqual(hits.last?.text, "row 991")
    }

    // MARK: file-name filter (dropdown)

    func testFilterLogNamesCaseInsensitiveSubstring() {
        XCTAssertEqual(filterLogNames(["usage.log", "pane-layout.log"], query: "USAGE"),
                       ["usage.log"])
        XCTAssertEqual(filterLogNames(["usage.log", "pane-layout.log"], query: "layout"),
                       ["pane-layout.log"])
    }

    func testFilterLogNamesEmptyQueryKeepsAll() {
        let names = ["usage.log", "pane-layout.log"]
        XCTAssertEqual(filterLogNames(names, query: ""), names)
    }

    func testFilterLogNamesNoMatchIsEmpty() {
        XCTAssertEqual(filterLogNames(["usage.log"], query: "codex"), [])
    }
}
