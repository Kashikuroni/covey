import XCTest
@testable import covey

final class WheelAccumulatorTests: XCTestCase {
    func testFractionsAccumulateToWholeLine() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: 4, rowHeight: 10), 1)   // 12 px -> 1 line, 2 px kept
        XCTAssertEqual(acc.add(pixels: 8, rowHeight: 10), 1)   // 2 + 8 = 10 px
    }

    func testNegativeDeltasEmitNegativeLines() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: -25, rowHeight: 10), -2) // -5 px kept
        XCTAssertEqual(acc.add(pixels: -5, rowHeight: 10), -1)
    }

    func testDirectionReversalDropsRemainder() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 9, rowHeight: 10), 0)
        XCTAssertEqual(acc.add(pixels: -9, rowHeight: 10), 0)   // NOT -1: +9 remainder dropped
        XCTAssertEqual(acc.add(pixels: -1, rowHeight: 10), -1)  // -9 + -1 = -10
    }

    func testLargeDeltaEmitsSeveralLinesAtOnce() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 35, rowHeight: 10), 3)
    }

    func testNonPositiveRowHeightIsNoop() {
        var acc = WheelAccumulator()
        XCTAssertEqual(acc.add(pixels: 100, rowHeight: 0), 0)
        XCTAssertEqual(acc.add(pixels: 100, rowHeight: -1), 0)
    }
}
