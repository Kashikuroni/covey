import XCTest
@testable import covey
import CoveyKit

final class LifecycleTests: XCTestCase {
    func testConfirmsRestart() {
        XCTAssertTrue(confirmsRestart("yes"))
        XCTAssertTrue(confirmsRestart("  YES "))
        XCTAssertTrue(confirmsRestart("да"))
        XCTAssertTrue(confirmsRestart("Да"))
        XCTAssertFalse(confirmsRestart("y"))
        XCTAssertFalse(confirmsRestart("yes!"))
        XCTAssertFalse(confirmsRestart(""))
        XCTAssertFalse(confirmsRestart("no"))
    }

    func testIsReturnable() {
        let wt = Session(name: "w", dir: "/r/.worktrees/f", cwd: "/r/.worktrees/f",
                         agent: "claude", created: 1, worktreeRepo: "/r")
        XCTAssertTrue(isReturnable(wt, dirExists: { _ in false }), "worktree dir gone")
        XCTAssertFalse(isReturnable(wt, dirExists: { _ in true }), "worktree alive")
        let plain = Session(name: "p", dir: "/gone", cwd: "/gone", agent: "sh", created: 1)
        XCTAssertFalse(isReturnable(plain, dirExists: { _ in false }),
                       "non-worktree session has no root to return to")
    }

    func testShellSingleQuote() {
        XCTAssertEqual(shellSingleQuote("/a b"), "'/a b'")
        XCTAssertEqual(shellSingleQuote("a'b"), "'a'\\''b'")
    }

    func testThemeRestartPlanSplitsIdleFromBusy() {
        func sess(_ name: String, _ agent: String) -> Session {
            Session(name: name, dir: "/tmp", cwd: "/tmp", agent: agent, created: 0)
        }
        let sessions = [sess("a", "claude"), sess("b", "claude opus"),
                        sess("c", "claude"), sess("d", "claude"), sess("e", "sh")]
        let statuses: [String: Status] = ["a": .idle, "b": .idle, "c": .running,
                                          "d": .waiting, "e": .idle]
        let plan = themeRestartPlan(sessions: sessions, statuses: statuses)
        XCTAssertEqual(plan.idle, ["a", "b"], "multi-word claude agent still counts")
        XCTAssertEqual(plan.busy, ["c", "d"], "waiting is busy; sh is not claude")
    }

    func testThemeRestartPlanMissingStatusIsBusy() {
        let s = Session(name: "a", dir: "/tmp", cwd: "/tmp", agent: "claude", created: 0)
        let plan = themeRestartPlan(sessions: [s], statuses: [:])
        XCTAssertEqual(plan.idle, [])
        XCTAssertEqual(plan.busy, ["a"])
    }

    func testThemeRestartPlanEmptyInput() {
        let plan = themeRestartPlan(sessions: [], statuses: [:])
        XCTAssertTrue(plan.idle.isEmpty)
        XCTAssertTrue(plan.busy.isEmpty)
    }
}
