import XCTest
import Foundation
@testable import covey

final class CodexFramingTests: XCTestCase {
    func testSplitsCompleteLinesAndKeepsRemainder() {
        var framer = JSONLFramer()
        let first = framer.push(Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":1}", "{\"b\":2}"])
        let second = framer.push(Data(":3}\n".utf8))
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
    }

    func testEmptyLinesAreDropped() {
        var framer = JSONLFramer()
        let lines = framer.push(Data("\n{\"a\":1}\n\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
    }

    func testNoNewlineYieldsNothing() {
        var framer = JSONLFramer()
        XCTAssertTrue(framer.push(Data("partial".utf8)).isEmpty)
    }
}
