import XCTest
@testable import CoveydCore

final class ScrollbackBufferTests: XCTestCase {
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
    
    func testSinceReadsAcrossRingWrap() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(bytes("ab"))
        b.append(bytes("cd"))
        b.append(bytes("ef")) // ring now holds "cdef", head=2, tail=6
        XCTAssertEqual(b.headSeq, 2)
        XCTAssertEqual(b.tailSeq, 6)
        let got = b.since(2)
        XCTAssertEqual(got.bytes, bytes("cdef"))
        XCTAssertEqual(got.fromSeq, 2)
        XCTAssertFalse(got.gapped)
    }

    func testOversizeAppendReturnsOnlySurvivingRange() {
        let buf = ScrollbackBuffer(limit: 8)
        let range = buf.append(Array("0123456789AB".utf8))   // 12 bytes, 8-byte ring
        XCTAssertEqual(range.to - range.from, 8, "range covers only surviving bytes")
        XCTAssertEqual(range.from, buf.headSeq)
        let (bytes, from, gapped) = buf.since(range.from)
        XCTAssertFalse(gapped, "an append's own range must not come back gapped")
        XCTAssertEqual(from, range.from)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "456789AB")
    }

}
