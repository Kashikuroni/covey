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
}
