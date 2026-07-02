import XCTest
@testable import CoveyKit

final class NDJSONCodecTests: XCTestCase {
    func testEncodeLineAppendsNewline() throws {
        let line = try NDJSON.encodeLine(["a": 1])
        XCTAssertEqual(line.last, 0x0A)                      // ends with '\n'
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"a\":1}\n")
    }

    func testFramerSplitsCompleteLines() throws {
        var f = LineFramer()
        let out = try f.feed(bytes("one\ntwo\n"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
    }

    func testFramerBuffersPartialLine() throws {
        var f = LineFramer()
        XCTAssertEqual(try f.feed(bytes("he")).count, 0)     // no newline yet
        let out = try f.feed(bytes("llo\n"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["hello"])
    }

    func testFramerHandlesMultipleAndTrailingPartial() throws {
        var f = LineFramer()
        let out = try f.feed(bytes("a\nb\nc"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        let rest = try f.feed(bytes("\n"))
        XCTAssertEqual(rest.map { String(decoding: $0, as: UTF8.self) }, ["c"])
    }

    func testFramerThrowsOnOverlongLine() {
        var f = LineFramer(maxLineLength: 4)
        XCTAssertThrowsError(try f.feed(bytes("abcde"))) {
            XCTAssertEqual($0 as? NDJSONError, NDJSONError.lineTooLong)
        }
    }
}
