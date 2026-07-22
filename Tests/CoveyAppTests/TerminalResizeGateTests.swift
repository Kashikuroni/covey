import XCTest
@testable import covey

final class TerminalResizeGateTests: XCTestCase {
    func testOnlyNewestResizeCanDeliverWhenCallbacksRunOutOfOrder() throws {
        let gate = TerminalResizeGate()
        let transient = try XCTUnwrap(gate.register(cols: 2, rows: 40))
        let stable = try XCTUnwrap(gate.register(cols: 100, rows: 40))

        XCTAssertFalse(gate.isLatest(transient))
        XCTAssertTrue(gate.isLatest(stable))
    }

    func testStableNarrowResizeRemainsDeliverable() throws {
        let gate = TerminalResizeGate()
        let narrow = try XCTUnwrap(gate.register(cols: 2, rows: 40))

        XCTAssertTrue(gate.isLatest(narrow))
        XCTAssertEqual(narrow.cols, 2)
        XCTAssertEqual(narrow.rows, 40)
    }
}
