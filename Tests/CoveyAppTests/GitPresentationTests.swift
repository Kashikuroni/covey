import XCTest
import CoveyKit
@testable import covey

final class GitPresentationTests: XCTestCase {
    func testCardDeltaUsesOnlyUnstagedLineCounts() {
        let info = GitInfo(
            branch: "feat",
            unstaged: .init(files: 1, added: 2, removed: 3),
            staged: .init(files: 1, added: 8, removed: 5),
            untracked: 4
        )
        XCTAssertEqual(
            sessionGitDelta(info),
            SessionGitDelta(added: 2, removed: 3)
        )
    }

    func testStagedOnlyDoesNotCreateCardDelta() {
        let info = GitInfo(
            branch: "feat", unstaged: .empty,
            staged: .init(files: 1, added: 8, removed: 5), untracked: 0
        )
        XCTAssertNil(sessionGitDelta(info))
    }

    func testUntrackedOnlyDoesNotCreateCardDelta() {
        let info = GitInfo(
            branch: "feat", unstaged: .empty, staged: .empty, untracked: 7
        )
        XCTAssertNil(sessionGitDelta(info))
    }

    func testZeroLineUnstagedChangeDoesNotCreateCardDelta() {
        let info = GitInfo(
            branch: "feat", unstaged: .init(files: 1, added: 0, removed: 0),
            staged: .empty, untracked: 0
        )
        XCTAssertNil(sessionGitDelta(info))
    }

    func testDeleteDestinationsExcludeSourceAndOtherWorktreesButAllowRoot() {
        XCTAssertEqual(
            branchDeleteDestinations(
                deleting: "feat",
                repoRoot: "/repo",
                branches: ["feat", "main", "other", "busy"],
                worktrees: ["main": "/repo", "busy": "/repo/.worktrees/busy"]
            ),
            ["main", "other"]
        )
    }

    func testPreferredDeleteDestinationUsesProtectedPriorityThenFirst() {
        XCTAssertEqual(
            preferredBranchDeleteDestination(["topic", "dev", "main"]),
            "main"
        )
        XCTAssertEqual(
            preferredBranchDeleteDestination(["topic", "other"]),
            "topic"
        )
        XCTAssertNil(preferredBranchDeleteDestination([]))
    }

    func testWorktreeDeleteGateAllowsCleanUnmergedFeatureBranch() {
        XCTAssertNil(worktreeBranchDeletionBlockReason(
            branch: "feat", dirty: false, merged: false
        ))
    }

    func testWorktreeDeleteGateBlocksDirtyAndProtectedBranches() {
        XCTAssertEqual(worktreeBranchDeletionBlockReason(
            branch: "feat", dirty: true, merged: false
        ), "Uncommitted changes")
        XCTAssertEqual(worktreeBranchDeletionBlockReason(
            branch: "main", dirty: false, merged: true
        ), "Branch is protected")
    }
}
