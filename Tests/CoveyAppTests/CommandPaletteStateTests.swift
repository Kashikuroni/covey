import XCTest
@testable import covey

final class CommandPaletteStateTests: XCTestCase {
    func testResetClearsQueryAndSelectsFirstEnabledCommand() {
        var state = CommandPaletteState(query: "old", selection: .killSession)
        state.reset(visible: [.killSession, .newSession]) { $0 == .newSession }
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selection, .newSession)
    }

    func testAllDisabledFallsBackToFirstVisibleForExplanation() {
        var state = CommandPaletteState()
        state.reset(visible: [.killSession, .restartSession]) { _ in false }
        XCTAssertEqual(state.selection, .killSession)
    }

    func testMoveWrapsAndIncludesDisabledRows() {
        var state = CommandPaletteState(selection: .newSession)
        let visible: [AppCommand] = [.newSession, .killSession, .settings]
        state.move(by: -1, visible: visible)
        XCTAssertEqual(state.selection, .settings)
        state.move(by: 1, visible: visible)
        XCTAssertEqual(state.selection, .newSession)
    }

    func testReplacingQuerySelectsFirstEnabledVisibleResult() {
        var state = CommandPaletteState(selection: .settings)
        state.replaceQuery(
            "split",
            visible: [.closeTerminalSplit, .splitTerminalVertically]
        ) { $0 == .splitTerminalVertically }

        XCTAssertEqual(state.query, "split")
        XCTAssertEqual(state.selection, .splitTerminalVertically)
    }

    func testReplacingQueryWithNoResultsClearsSelection() {
        var state = CommandPaletteState(selection: .settings)
        state.replaceQuery("nothing", visible: []) { _ in true }

        XCTAssertNil(state.selection)
    }
}
