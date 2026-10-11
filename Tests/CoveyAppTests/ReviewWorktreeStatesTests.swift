import XCTest
import CoveyGit
@testable import covey

final class ReviewWorktreeStatesTests: XCTestCase {
    private let now: Int64 = 1_760_000_000

    func testStateTable() {                                          // Review Focus 6
        XCTAssertEqual(reviewWorktreeState(isPrimary: true, hasLiveSession: true, branchIsBase: false,
                                           clean: true, mergedIntoBase: true, ahead: 0,
                                           lastCommit: now, now: now), .root)
        XCTAssertEqual(reviewWorktreeState(isPrimary: false, hasLiveSession: true, branchIsBase: false,
                                           clean: false, mergedIntoBase: false, ahead: 3,
                                           lastCommit: now, now: now), .active)
        XCTAssertEqual(reviewWorktreeState(isPrimary: false, hasLiveSession: false, branchIsBase: true,
                                           clean: false, mergedIntoBase: false, ahead: 0,
                                           lastCommit: nil, now: now), .idle)
        // Donor order, meaningful case 1: merged + dirty ⇒ Idle, not Done.
        XCTAssertEqual(reviewWorktreeState(isPrimary: false, hasLiveSession: false, branchIsBase: false,
                                           clean: false, mergedIntoBase: true, ahead: 0,
                                           lastCommit: now, now: now), .idle)
        // Donor order, meaningful case 2: old + ahead ⇒ Stale, not Idle.
        XCTAssertEqual(reviewWorktreeState(isPrimary: false, hasLiveSession: false, branchIsBase: false,
                                           clean: true, mergedIntoBase: false, ahead: 2,
                                           lastCommit: now - 15 * 24 * 3600, now: now), .stale)
        XCTAssertEqual(reviewWorktreeState(isPrimary: false, hasLiveSession: false, branchIsBase: false,
                                           clean: true, mergedIntoBase: true, ahead: 0,
                                           lastCommit: now, now: now), .done)
    }

    func testCleanupCandidatesExcludeRootAndUnsafe() {
        func row(_ path: String, primary: Bool = false, state: ReviewWorktreeState = .done,
                 clean: Bool = true, merged: Bool = true, ahead: Int = 0) -> WorktreeRow {
            WorktreeRow(path: path, branch: "b-\(path)", isPrimary: primary, state: state,
                        agent: nil, clean: clean, mergedIntoBase: merged, ahead: ahead,
                        lastCommit: nil, isCurrent: false)
        }
        let rows = [
            row("/r", primary: true, state: .root),
            row("/done"),
            row("/dirty", state: .idle, clean: false, merged: true),
            row("/unmerged", state: .idle, clean: true, merged: false, ahead: 2),
        ]
        let candidates = cleanupCandidates(rows)
        XCTAssertEqual(candidates.map(\.path), ["/done"])
        XCTAssertEqual(candidates[0].ticked, true)
        XCTAssertEqual(candidates[0].canDeleteBranch, true)
    }

    func testCleanupConfirmLabelPluralizes() {
        XCTAssertEqual(cleanupConfirmLabel(worktrees: 1, branches: 0), "Remove 1 worktree")
        XCTAssertEqual(cleanupConfirmLabel(worktrees: 2, branches: 1), "Remove 2 worktrees and 1 branch")
        XCTAssertEqual(cleanupConfirmLabel(worktrees: 2, branches: 3), "Remove 2 worktrees and 3 branches")
        XCTAssertEqual(cleanupConfirmLabel(worktrees: 0, branches: 0), "Remove nothing")
    }

    func testIsLiveSessionMatchesByPathPrefix() {
        let sessions = [(dir: "/repo/.worktrees/feat", agent: "codex-1")]
        XCTAssertEqual(isLiveSession("/repo/.worktrees/feat", sessions: sessions), "codex-1")
        XCTAssertNil(isLiveSession("/repo/.worktrees/other", sessions: sessions))
        XCTAssertNil(isLiveSession("/repo", sessions: []))
    }
}

extension ReviewWorktreeStatesTests {
    func testCleanupButtonLabelPrefersRetry() {                      // review minor 2
        XCTAssertEqual(cleanupButtonLabel(failed: 1, worktrees: 1, branches: 1),
                       "Retry 1 worktree")
        XCTAssertEqual(cleanupButtonLabel(failed: 0, worktrees: 2, branches: 1),
                       "Remove 2 worktrees and 1 branch")
        XCTAssertEqual(cleanupButtonLabel(failed: 0, worktrees: 0, branches: 0),
                       "Remove nothing")
    }
}
