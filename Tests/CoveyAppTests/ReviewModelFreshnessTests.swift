import XCTest
import CoreGraphics
import CoveyGit
import CoveyKit
@testable import covey

@MainActor
final class ReviewModelFreshnessTests: XCTestCase {
    private let d1 = oneHunk([(.added, nil, 1, "one")])
    private let d2 = oneHunk([(.added, nil, 1, "one"), (.added, nil, 2, "two")])

    private func started(_ files: [ChangedFile] = [changed("a.swift")],
                         stamps: [String: FileStamp] = [:]) async -> (ReviewModel, FakeReviewGit) {
        let git = FakeReviewGit()
        git.state = comparisonState(files, stamps: stamps)
        git.diffs["a.swift"] = d1
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        return (model, git)
    }

    func testUnchangedFingerprintDoesNotReload() async {
        let (model, git) = await started()
        await model.checkFreshness()
        XCTAssertEqual(git.fingerprintCalls, 1)
        XCTAssertEqual(git.changesCalls, 1)
    }

    func testChangedFingerprintReloadsAndNewFilesAreUnread() async {
        let (model, git) = await started()
        git.state = comparisonState([changed("a.swift"), changed("b.swift", .added)], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertEqual(git.changesCalls, 2)
        XCTAssertEqual(model.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(model.review(for: "b.swift").state, .unread)
    }

    func testReviewedFileWhoseDiffChangedFallsBackToReviewing() async {
        let (model, git) = await started()
        await model.select("a.swift")
        await model.toggleReviewed()
        git.state = comparisonState([changed("a.swift", added: 2)], fingerprint: "fp-2")
        git.diffs["a.swift"] = d2
        await model.checkFreshness()
        let review = model.review(for: "a.swift")
        XCTAssertEqual(review.state, .reviewing)
        XCTAssertTrue(review.changedSinceReviewed)
        XCTAssertNil(review.reviewedDiffHash)
    }

    func testTouchedButIdenticalReviewedFileStaysReviewed() async {
        let (model, git) = await started(stamps: ["a.swift": FileStamp(mtime: 1, size: 4)])
        await model.select("a.swift")
        await model.toggleReviewed()
        git.state = comparisonState([changed("a.swift")], fingerprint: "fp-2",
                                    stamps: ["a.swift": FileStamp(mtime: 2, size: 4)])
        await model.checkFreshness()
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewed)
    }

    func testComposerDraftSurvivesReload() async {
        let (model, git) = await started()
        await model.select("a.swift")
        model.openComposer(side: .new, line: 1, text: "one")
        model.composer?.draft = "half-typed thought"
        git.state = comparisonState([changed("a.swift", added: 2)], fingerprint: "fp-2")
        git.diffs["a.swift"] = d2
        await model.checkFreshness()
        XCTAssertEqual(model.composer?.draft, "half-typed thought")
        XCTAssertEqual(model.diff, .loaded(d2))
    }

    func testSelectedFileThatLeftTheComparisonClosesTheDiff() async {
        let (model, git) = await started()
        await model.select("a.swift")
        git.state = comparisonState([changed("b.swift")], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertNil(model.selectedPath)
        XCTAssertFalse(model.diffOpen)
        XCTAssertEqual(model.diff, .idle)
    }

    func testFailuresSetABannerAndBackOffThenRecover() async {
        let (model, git) = await started()
        git.fingerprintError = GitError(kind: .failed(status: 128), description: "fatal: index locked")
        await model.checkFreshness()
        await model.checkFreshness()
        XCTAssertEqual(model.banner, "fatal: index locked")
        XCTAssertEqual(model.pollDelay, 12)
        git.fingerprintError = nil
        await model.checkFreshness()
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.pollDelay, 3)
    }

    func testAgentFinishingTriggersACheck() async {
        let (model, git) = await started()
        await model.targetStatusChanged(from: .idle, to: .running)
        XCTAssertEqual(git.fingerprintCalls, 0)
        await model.targetStatusChanged(from: .running, to: .idle)
        XCTAssertEqual(git.fingerprintCalls, 1)
    }

    func testNothingPollsBeforeTheReviewIsReady() async {
        let git = FakeReviewGit()
        git.base = nil
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.checkFreshness()
        XCTAssertEqual(git.fingerprintCalls, 0)
    }

    func testRetryReloadsALoadedReview() async {
        let (model, git) = await started()
        await model.retry()
        XCTAssertEqual(git.changesCalls, 2)
        XCTAssertEqual(model.phase, .ready)
    }

    // MARK: - Races and canvas fitting

    /// A poll-triggered reload of comparison A is parked in `changes`; the
    /// user opens B meanwhile. When A's read finally lands it must not touch B.
    func testAbandonedReloadDoesNotTouchTheNewComparison() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.statesByBase["b"] = comparisonState([changed("only-b.swift")], fingerprint: "fp-b")
        git.diffs["only-b.swift"] = d1
        let (model, store) = makeReviewModel(git: git)
        await model.start()
        let b = GitComparison(base: "b")

        // The fake answers A's held read from `state`, so this is what would land.
        git.state = comparisonState([changed("a.swift"), changed("late.swift", .added)], fingerprint: "fp-2")
        let held = git.holdNextChanges(base: "main")
        let poll = Task { await model.checkFreshness() }
        await held.waitUntilArrived()
        await model.open(b)
        await model.select("only-b.swift")
        await model.toggleReviewed()

        held.release()
        await poll.value
        XCTAssertEqual(model.record.comparison, b)
        XCTAssertEqual(model.files.map(\.path), ["only-b.swift"])
        XCTAssertEqual(model.state?.fingerprint, "fp-b")
        XCTAssertEqual(Set(model.record.files.keys), ["only-b.swift"])
        XCTAssertEqual(model.review(for: "only-b.swift").state, .reviewed)
        XCTAssertEqual(model.selectedPath, "only-b.swift")
        XCTAssertEqual(model.diff, .loaded(d1))
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.pollDelay, 3)
        store.flush()
        XCTAssertEqual(Set(store.load(worktree: model.worktree, comparison: b).record.files.keys),
                       ["only-b.swift"])
    }

    /// The abandoned reload is already past `changes` and parked in the
    /// re-diff of a reviewed file; it must not write that verdict into B's record.
    func testAbandonedReloadStopsBeforeInvalidatingTheNewComparisonsFiles() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = d1
        git.statesByBase["b"] = comparisonState([changed("a.swift")], fingerprint: "fp-b")
        let (model, store) = makeReviewModel(git: git)
        let b = GitComparison(base: "b")
        var seeded = ReviewRecord(worktree: model.worktree, comparison: b)
        seeded.files["a.swift"] = FileReview(state: .reviewed, reviewedDiffHash: "saved-hash")
        store.save(seeded)
        store.flush()
        await model.start()
        await model.select("a.swift")
        await model.toggleReviewed()

        git.state = comparisonState([changed("a.swift", added: 2)], fingerprint: "fp-2")
        git.diffs["a.swift"] = d2
        let held = git.holdNextDiff(fullFile: false)
        let poll = Task { await model.checkFreshness() }
        await held.waitUntilArrived()
        await model.open(b)

        held.release()
        await poll.value
        XCTAssertEqual(model.record.comparison, b)
        let review = model.review(for: "a.swift")
        XCTAssertEqual(review.state, .reviewed)
        XCTAssertEqual(review.reviewedDiffHash, "saved-hash")
        XCTAssertFalse(review.changedSinceReviewed)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.state?.fingerprint, "fp-b")
    }

    func testCanvasFitsWhenFilesFirstAppearThroughReload() async {
        let git = FakeReviewGit()
        git.state = comparisonState([])
        let (model, _) = makeReviewModel(git: git)
        model.setCanvasViewport(CGSize(width: 800, height: 600))
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.canvas, CanvasTransform())

        git.state = comparisonState([changed("a.swift")], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertEqual(model.files.map(\.path), ["a.swift"])
        XCTAssertNotEqual(model.canvas, CanvasTransform())
    }

    func testReloadKeepsACanvasTheReviewerMovedAfterTheFirstFit() async {
        let (model, git) = await started()
        model.setCanvasViewport(CGSize(width: 800, height: 600))
        model.canvas = model.canvas.panned(by: CGSize(width: 40, height: 40))
        let moved = model.canvas
        git.state = comparisonState([changed("a.swift"), changed("b.swift", .added)], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertEqual(model.files.count, 2)
        XCTAssertEqual(model.canvas, moved)
    }
}
