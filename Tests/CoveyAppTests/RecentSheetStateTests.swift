import XCTest
@testable import covey
import CoveyKit

final class RecentSheetStateTests: XCTestCase {
    private func item(_ name: String, stopped: Int64?, branch: String? = nil,
                      root: String = "/repos/ms", project: String = "Mentor Solution")
        -> RecentSearchItem {
        RecentSearchItem(
            session: RecentSession(name: name, dir: root, agent: "claude",
                                   stoppedAt: stopped, branch: branch),
            projectRoot: root,
            projectName: project)
    }

    func testResultsSortNewestFirstNilLastAndKeepTiesStable() {
        let input = [item("nil-a", stopped: nil), item("old", stopped: 10),
                     item("new-a", stopped: 20), item("new-b", stopped: 20),
                     item("nil-b", stopped: nil)]
        XCTAssertEqual(recentResults(input, query: "").map(\.id),
                       ["new-a", "new-b", "old", "nil-a", "nil-b"])
    }

    func testResultsSearchNameBranchProjectNameAndRoot() {
        let input = [
            item("api-fix", stopped: 20, branch: "feature/auth"),
            item("notes", stopped: 10, root: "/repos/covey", project: "Covey"),
        ]
        XCTAssertEqual(recentResults(input, query: "apfx").map(\.id), ["api-fix"])
        XCTAssertEqual(recentResults(input, query: "fauth").map(\.id), ["api-fix"])
        XCTAssertEqual(recentResults(input, query: "ms").map(\.id), ["api-fix"])
        XCTAssertEqual(recentResults(input, query: "covey").map(\.id), ["notes"])
    }

    func testProjectRenameChangesSearchWithoutChangingRecent() {
        let session = RecentSession(name: "api", dir: "/repos/ms", agent: "claude")
        let before = RecentSearchItem(session: session, projectRoot: "/repos/ms",
                                      projectName: "MS")
        let after = RecentSearchItem(session: session, projectRoot: "/repos/ms",
                                     projectName: "Mentor Solution")
        XCTAssertTrue(recentResults([before], query: "mentor").isEmpty)
        XCTAssertEqual(recentResults([after], query: "mentor").map(\.id), ["api"])
    }

    func testSheetHeightUsesIntrinsicRowsAndCapsAtSixtyPercent() {
        XCTAssertEqual(recentSheetHeight(rowCount: 1, screenHeight: 1000), 250)
        XCTAssertEqual(recentSheetHeight(rowCount: 20, screenHeight: 1000), 600)
    }

    func testFocusFlowAndNavigationUseFilteredRows() {
        let rows = [item("new", stopped: 20), item("old", stopped: 10)]
        var state = RecentSheetState()
        state.open(rows: rows)
        XCTAssertEqual(state.focus, .list)
        XCTAssertEqual(state.selectedName, "new")

        state.focusSearch()
        XCTAssertEqual(state.focus, .search)
        state.query = "old"
        let filtered = state.results(from: rows)
        state.commitSearch(rows: filtered)
        XCTAssertEqual(state.focus, .list)
        XCTAssertEqual(state.selectedName, "old")
        state.move(1, rows: filtered)
        XCTAssertEqual(state.selectedName, "old")
    }

    func testSuccessfulRestoreSelectsReplacementAndFailureKeepsSelection() {
        let rows = [item("a", stopped: 30), item("b", stopped: 20),
                    item("c", stopped: 10)]
        var state = RecentSheetState()
        state.open(rows: rows)
        XCTAssertTrue(state.beginRestore("a"))
        state.completeRestore("a", succeeded: true, visibleBefore: rows)
        XCTAssertEqual(state.results(from: rows).map(\.id), ["b", "c"])
        XCTAssertEqual(state.selectedName, "b")

        XCTAssertTrue(state.beginRestore("b"))
        let trigger = state.failureTriggers["b", default: 0]
        state.completeRestore("b", succeeded: false,
                              visibleBefore: state.results(from: rows))
        XCTAssertEqual(state.selectedName, "b")
        XCTAssertEqual(state.failureTriggers["b"], trigger + 1)
        XCTAssertEqual(state.results(from: rows).map(\.id), ["b", "c"])
    }
}
