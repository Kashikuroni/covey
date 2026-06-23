import XCTest
@testable import CoveydCore

final class ScrollbackBufferTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        Array(s.utf8)
    }
    private func assertSince(
        _ buffer: ScrollbackBuffer,
        from seq: Int,
        equals expected: String,
        fromSeq: Int,
        gapped: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let got = buffer.since(seq)
        XCTAssertEqual(
            got.bytes, bytes(expected), file: file, line: line
        )
        XCTAssertEqual(
            got.fromSeq, fromSeq, "fromSeq", file: file, line: line
        )
        XCTAssertEqual(
            got.gapped, gapped, "gapped", file: file, line: line
        )
    }
    func testAppendAdvancesTailAndSinceZeroReturnsAll() {
        let b = ScrollbackBuffer(limit: 1024)
        let r = b.append(bytes("hello"))
        XCTAssertEqual(r.from, 0)
        XCTAssertEqual(r.to, 5)
        XCTAssertEqual(b.tailSeq, 5)
        assertSince(
            b, from: 0, equals: "hello", fromSeq: 0, gapped: false
        )
    }

    func testSinceFromMiddle() {
        let b = ScrollbackBuffer(limit: 1024)
        b.append(bytes("abcdef"))
        assertSince(
            b, from: 2, equals: "cdef", fromSeq: 2, gapped: false
        )
    }

    func testOverflowEvictsAndAdvancesHead() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(bytes("abcdef"))
        XCTAssertEqual(b.headSeq, 2)
        XCTAssertEqual(b.tailSeq, 6)
        assertSince(
            b, from: 2, equals: "cdef", fromSeq: 2, gapped: false
        )
    }

    func testSinceEvictedSeqIsGapped() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(bytes("abcdef")) // head advanced to 2
        assertSince(b, from: 0, equals: "cdef", fromSeq: 2, gapped: true)
    }

    func testEmptyAndBeyondTail() {
        let b = ScrollbackBuffer(limit: 16)
        assertSince(b, from: 0, equals: "", fromSeq: 0, gapped: false)
        b.append(bytes("xy"))
        assertSince(b, from: 10, equals: "", fromSeq: 2, gapped: false)
    }
}
