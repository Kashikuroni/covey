import XCTest
import CoveyGit
@testable import covey

@MainActor
final class ReviewModelCommittedTests: XCTestCase {
    /// `feat/x` against `main`, per FakeReviewGit's defaults.
    private func startedModel(files: [ChangedFile], ahead: Int = 0,
                              fingerprint: String = "fp-1") async -> (ReviewModel, FakeReviewGit) {
        let git = FakeReviewGit()
        git.state = comparisonState(files, fingerprint: fingerprint)
        git.aheadBehindByBranch["feat/x"] = (ahead: ahead, behind: 0)
        let (model, _) = makeReviewModel(git: git)
        model.isVisible = true
        await model.start()
        return (model, git)
    }

    func testAnEmptyWorkingTreeOverAnAheadBranchOffersTheCommittedWork() async {
        let (model, _) = await startedModel(files: [], ahead: 3)
        XCTAssertEqual(model.committedReviewOffer,
                       CommittedReviewOffer(base: "main", branch: "feat/x", ahead: 3))
    }

    func testADirtyTreeOrAnEvenBranchOffersNothing() async {
        let (dirty, _) = await startedModel(files: [changed("a.swift")], ahead: 3)
        XCTAssertNil(dirty.committedReviewOffer, "the tree still has work to review here")

        let (even, _) = await startedModel(files: [], ahead: 0)
        XCTAssertNil(even.committedReviewOffer, "nothing was committed past the base")
    }

    func testOpeningTheOfferReviewsBaseAgainstTheBranchAndClearsIt() async {
        let (model, _) = await startedModel(files: [], ahead: 2)
        await model.openCommittedReview()
        XCTAssertEqual(model.record.comparison, GitComparison(base: "main", head: .ref("feat/x")))
        XCTAssertNil(model.committedReviewOffer, "a ref comparison has no working tree to offer about")
    }

    func testACommitWhileReviewingRaisesTheOfferOnTheNextReload() async {
        let (model, git) = await startedModel(files: [changed("a.swift")], ahead: 0,
                                              fingerprint: "fp-1")
        XCTAssertNil(model.committedReviewOffer)
        git.state = comparisonState([], fingerprint: "fp-2")
        git.fingerprintValue = "fp-2"
        git.aheadBehindByBranch["feat/x"] = (ahead: 1, behind: 0)
        await model.checkFreshness()
        XCTAssertEqual(model.committedReviewOffer?.ahead, 1, "the agent committed everything")
    }

    // MARK: Review carryover

    /// A fresh store plus the reviewer's marks from `main…working tree`.
    private func storeWithWorkingTreeReview(worktree: String) -> ReviewStore {
        let store = ReviewStore(root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))",
                                debounce: 0)
        var prior = ReviewRecord(worktree: worktree, comparison: GitComparison(base: "main"))
        prior.files["a.swift"] = FileReview(state: .reviewed, reviewedDiffHash: "h")
        prior.nextIssueId = 7
        prior.targetSession = "agent-1"
        store.save(prior)
        store.flush()
        return store
    }

    func testFirstOpenOfTheBranchComparisonInheritsTheWorkingTreeReview() async {
        let worktree = "\(NSTemporaryDirectory())covey-wt-\(UInt32.random(in: 0..<UInt32.max))"
        let store = storeWithWorkingTreeReview(worktree: worktree)
        let git = FakeReviewGit()
        git.state = comparisonState([])
        let (model, _) = makeReviewModel(git: git, store: store, worktree: worktree)
        model.isVisible = true

        await model.open(GitComparison(base: "main", head: .ref("feat/x")))
        XCTAssertEqual(model.record.comparison, GitComparison(base: "main", head: .ref("feat/x")))
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewed,
                       "the working-tree review continues on the branch")
        XCTAssertEqual(model.record.nextIssueId, 7)
        XCTAssertEqual(model.record.targetSession, "agent-1")
    }

    func testAnExistingBranchRecordIsNeverOverwritten() async {
        let worktree = "\(NSTemporaryDirectory())covey-wt-\(UInt32.random(in: 0..<UInt32.max))"
        let store = storeWithWorkingTreeReview(worktree: worktree)
        var own = ReviewRecord(worktree: worktree, comparison: GitComparison(base: "main", head: .ref("feat/x")))
        own.nextIssueId = 3
        store.save(own)
        store.flush()

        let git = FakeReviewGit()
        git.state = comparisonState([])
        let (model, _) = makeReviewModel(git: git, store: store, worktree: worktree)
        model.isVisible = true

        await model.open(GitComparison(base: "main", head: .ref("feat/x")))
        XCTAssertEqual(model.record.nextIssueId, 3, "the branch review keeps its own record")
        XCTAssertNil(model.record.files["a.swift"], "nothing was carried over")
    }
}
