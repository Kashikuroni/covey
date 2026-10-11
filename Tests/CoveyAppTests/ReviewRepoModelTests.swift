import XCTest
import CoveyGit
@testable import covey

@MainActor
final class ReviewRepoModelTests: XCTestCase {
    private let stamp: Int64 = 1_760_000_000

    private func makeModel(sessions: [(dir: String, agent: String)] = []) -> (ReviewRepoModel, FakeReviewGit, FakeReviewPRs) {
        let git = FakeReviewGit()
        git.worktreeEntries = [
            WorktreeListEntry(path: "/repo", branch: "main", isPrimary: true),
            WorktreeListEntry(path: "/repo/.worktrees/feat", branch: "feat", isPrimary: false),
        ]
        git.base = "main"
        git.mergedInto = ["feat"]
        git.lastCommitStamps = ["/repo": stamp, "/repo/.worktrees/feat": stamp]
        git.summaries = ["/repo/.worktrees/feat": WorkingTreeSummary(
            branch: "feat", unstaged: .empty, staged: .empty, untracked: 0)]
        let prs = FakeReviewPRs()
        let model = ReviewRepoModel(
            projectRoot: "/repo", currentWorktree: "/repo/.worktrees/feat",
            git: git, prReader: prs, liveSessions: { sessions })
        return (model, git, prs)
    }

    func testReloadBuildsRowsWithStatesAndPRs() async throws {
        let (model, _, prs) = makeModel()
        prs.snapshot = PRSnapshot(prs: [ReviewPR(number: 12, state: "OPEN", headRefName: "feat",
                                                 url: "u12", isDraft: false, title: "feat")], error: nil)

        await model.reload()

        XCTAssertEqual(model.base, "main")
        XCTAssertEqual(model.worktreeRows.count, 2)
        XCTAssertEqual(model.worktreeRows[0].state, .root)
        let feat = try XCTUnwrap(model.worktreeRows.first { $0.path == "/repo/.worktrees/feat" })
        XCTAssertEqual(feat.state, .done)
        XCTAssertEqual(feat.isCurrent, true)
        XCTAssertEqual(model.prs.count, 1)
        XCTAssertNil(model.prError)
    }

    func testCheckoutUnderLiveAgentIsRefused() async {           // Review Focus guard
        let (model, git, _) = makeModel(sessions: [(dir: "/repo/.worktrees/feat", agent: "codex-1")])
        await model.reload()

        await model.checkout("main", in: "/repo/.worktrees/feat")

        XCTAssertTrue(git.checkoutCalls.isEmpty)
        XCTAssertEqual(model.rowErrors["/repo/.worktrees/feat"]?.isEmpty, false)
    }

    func testCheckoutWithoutSessionGoesThrough() async {
        let (model, git, _) = makeModel()
        await model.reload()
        await model.checkout("main", in: "/repo/.worktrees/feat")
        XCTAssertEqual(git.checkoutCalls.count, 1)
        XCTAssertEqual(git.checkoutCalls[0].branch, "main")
    }

    func testUpdateFromBaseUnderLiveAgentIsRefused() async {
        let (model, git, _) = makeModel(sessions: [(dir: "/repo/.worktrees/feat", agent: "codex-1")])
        await model.reload()
        XCTAssertFalse(model.canUpdateFromBase)
        await model.updateFromBase()
        XCTAssertTrue(git.updateFromBaseCalls.isEmpty)
    }

    func testUpdateFromBaseCallsGitAndReloads() async {
        let (model, git, _) = makeModel()
        await model.reload()
        XCTAssertTrue(model.canUpdateFromBase)
        await model.updateFromBase()
        XCTAssertEqual(git.updateFromBaseCalls.count, 1)
        XCTAssertEqual(git.updateFromBaseCalls[0].base, "main")
    }

    func testRemoveCurrentWorktreeDoesNotTouchReviewModel() async {   // Review Focus 1
        let (model, git, _) = makeModel()
        await model.reload()

        // Removing the reviewed worktree is an ordinary op for this model:
        // it must run and refresh — ReviewModel's own freshness loop owns the
        // missing-worktree transition (existing tests cover it).
        await model.removeWorktree("/repo/.worktrees/feat", deleteBranchToo: true)
        XCTAssertEqual(git.removeCalls, ["/repo/.worktrees/feat"])
        XCTAssertEqual(git.branchDeleteCalls.count, 1)
        XCTAssertEqual(git.branchDeleteCalls[0].branch, "feat")
        XCTAssertTrue(git.branchDeleteCalls[0].protected.contains("main"))
    }

    func testDeleteBranchPassesProtectionList() async {
        let (model, git, _) = makeModel()
        await model.reload()
        await model.deleteBranch("feat")
        XCTAssertEqual(git.branchDeleteCalls.count, 1)
        XCTAssertTrue(git.branchDeleteCalls[0].protected.contains("main"))
    }

    func testOpenCleanupSheetBuildsPreTickedCandidates() async {
        let (model, _, _) = makeModel()
        await model.reload()
        model.openCleanupSheet()
        XCTAssertTrue(model.cleanupSheetOpen)
        XCTAssertEqual(model.cleanupRows.map(\.path), ["/repo/.worktrees/feat"])
        XCTAssertEqual(model.cleanupRows[0].ticked, true)
        XCTAssertEqual(model.cleanupRows[0].removeBranch, true)
    }

    func testRunCleanupReportsPartialFailureAndClosesOnSuccess() async {
        let (model, git, _) = makeModel()
        git.opsError = GitError("git refuse demo")
        await model.reload()
        model.openCleanupSheet()

        await model.runCleanup()
        XCTAssertEqual(model.cleanupRows[0].error, "git refuse demo")
        XCTAssertTrue(model.cleanupSheetOpen, "failures keep the sheet open")

        git.opsError = nil
        model.cleanupRows[0].error = nil
        await model.runCleanup()
        XCTAssertTrue(model.cleanupRows[0].done)
        XCTAssertFalse(model.cleanupSheetOpen, "all-good closes the sheet")
    }

    func testNewWorktreeReturnsErrorTextOnFailure() async {
        let (model, git, _) = makeModel()
        await model.reload()                                       // loads base = "main"
        git.opsError = GitError("branch 'dup' already exists — pick another name")
        let error = await model.newWorktree(name: "dup", base: nil)
        XCTAssertEqual(error, "branch 'dup' already exists — pick another name")
        XCTAssertEqual(git.worktreeAddCalls.count, 1)
        XCTAssertEqual(git.worktreeAddCalls[0].base, "main")      // base defaulted
    }
}

/// Scripted PRs for the repo model tests.
final class FakeReviewPRs: ReviewPRReading {
    var snapshot = PRSnapshot(prs: [], error: nil)
    private var loaded = false

    func load(root: String) async -> PRSnapshot { loaded = true; return snapshot }
    func refresh(root: String) async -> PRSnapshot { loaded = true; return snapshot }
}

extension ReviewRepoModelTests {
    func testCleanupAvailabilityCountsComeFromWorktreeRows() async {   // review fix C2
        let (model, _, _) = makeModel()          // one Done worktree; cleanupRows untouched
        await model.reload()
        XCTAssertEqual(model.cleanupRows.count, 0)
        let counts = model.cleanupAvailabilityCounts()
        XCTAssertEqual(counts.worktrees, 1)
        XCTAssertEqual(counts.branches, 1)
    }

    func testRemoveDirtyWorktreeRequiresConfirmation() async {         // review fix I1
        let (model, git, _) = makeModel()
        git.summaries["/repo/.worktrees/feat"] = WorkingTreeSummary(
            branch: "feat", unstaged: DiffTotals(files: 1, added: 1, removed: 0),
            staged: .empty, untracked: 0)
        await model.reload()

        await model.removeWorktree("/repo/.worktrees/feat", deleteBranchToo: false, confirmed: false)
        XCTAssertTrue(git.removeCalls.isEmpty, "dirty worktree needs an explicit confirm")
        XCTAssertEqual(model.rowErrors["/repo/.worktrees/feat"]?.isEmpty, false)

        await model.removeWorktree("/repo/.worktrees/feat", deleteBranchToo: false, confirmed: true)
        XCTAssertEqual(git.removeCalls, ["/repo/.worktrees/feat"])
    }

    func testEscapeClosesCleanupSheet() async {                        // review fix I2
        let (model, _, _) = makeModel()
        await model.reload()
        model.openCleanupSheet()
        XCTAssertTrue(model.escapeCleanupSheet())
        XCTAssertFalse(model.cleanupSheetOpen)
        XCTAssertFalse(model.escapeCleanupSheet())                     // nothing to close
    }
}
