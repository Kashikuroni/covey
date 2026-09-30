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

    /// The worktree was removed under the review (its branch merged and the
    /// worktree cleaned up): not a Retry banner for ever — the review is gone.
    func testAFailedCheckOnAVanishedWorktreeIsAMissingWorktree() async throws {
        let dir = "\(NSTemporaryDirectory())covey-worktree-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, _) = makeReviewModel(git: git, worktree: dir)
        await model.start()
        XCTAssertEqual(model.phase, .ready, "precondition: the review loaded")

        try FileManager.default.removeItem(atPath: dir)
        git.fingerprintError = GitError(kind: .failed(status: 128), description: "fatal: cannot change to '\(dir)'")
        await model.checkFreshness()
        XCTAssertEqual(model.phase, .missingWorktree)
        XCTAssertNil(model.banner)
    }

    /// The fingerprint read works but the reload behind it keeps failing: the
    /// backoff must keep growing instead of resetting on every fingerprint.
    func testBackoffGrowsWhenTheReloadKeepsFailing() async {
        let (model, git) = await started()
        git.fingerprintValue = "fp-moved"
        git.changesError = GitError(kind: .failed(status: 128), description: "fatal: index locked")
        await model.checkFreshness()
        await model.checkFreshness()
        await model.checkFreshness()
        XCTAssertEqual(git.changesCalls, 4)
        XCTAssertEqual(model.banner, "fatal: index locked")
        XCTAssertEqual(model.pollDelay, 30)

        git.changesError = nil
        git.fingerprintValue = nil
        git.state = comparisonState([changed("a.swift")], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.pollDelay, 3)
    }

    /// A reviewed file whose counts changed cannot be confirmed unchanged when
    /// its re-diff fails, so it goes back to reviewing rather than staying ✓.
    func testFailedRediffDemotesAReviewedFileWhoseCountsChanged() async {
        let (model, git) = await started()
        await model.select("a.swift")
        await model.toggleReviewed()
        git.state = comparisonState([changed("a.swift", added: 2)], fingerprint: "fp-2")
        git.diffError = GitError(kind: .timedOut, description: "timed out")
        await model.checkFreshness()
        let review = model.review(for: "a.swift")
        XCTAssertEqual(review.state, .reviewing)
        XCTAssertTrue(review.changedSinceReviewed)
        XCTAssertNil(review.reviewedDiffHash)
    }

    func testFailedRediffKeepsAReviewedFileWhoseStampAloneMoved() async {
        let (model, git) = await started(stamps: ["a.swift": FileStamp(mtime: 1, size: 4)])
        await model.select("a.swift")
        await model.toggleReviewed()
        git.state = comparisonState([changed("a.swift")], fingerprint: "fp-2",
                                    stamps: ["a.swift": FileStamp(mtime: 2, size: 4)])
        git.diffError = GitError(kind: .timedOut, description: "timed out")
        await model.checkFreshness()
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewed)
        XCTAssertFalse(model.review(for: "a.swift").changedSinceReviewed)
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
    /// B's saved hash matches the diff B loads (d2), so `open` keeps it reviewed;
    /// the parked read answers something else once released, and would demote it.
    func testAbandonedReloadStopsBeforeInvalidatingTheNewComparisonsFiles() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = d1
        git.statesByBase["b"] = comparisonState([changed("a.swift")], fingerprint: "fp-b")
        let (model, store) = makeReviewModel(git: git)
        let b = GitComparison(base: "b")
        let bHash = ReviewHash.of(d2, file: changed("a.swift"), stamp: nil)
        var seeded = ReviewRecord(worktree: model.worktree, comparison: b)
        seeded.files["a.swift"] = FileReview(state: .reviewed, reviewedDiffHash: bHash)
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
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewed)

        git.diffs["a.swift"] = oneHunk([(.added, nil, 1, "edited after the switch")])
        held.release()
        await poll.value
        XCTAssertEqual(model.record.comparison, b)
        let review = model.review(for: "a.swift")
        XCTAssertEqual(review.state, .reviewed)
        XCTAssertEqual(review.reviewedDiffHash, bHash)
        XCTAssertFalse(review.changedSinceReviewed)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.state?.fingerprint, "fp-b")
    }

    /// The agent kept editing while the comparison was not loaded (window
    /// closed, or A → B → A): nothing polls a state it just loaded, so `open`
    /// itself must catch the reviewed file whose diff moved on.
    func testOpenDemotesReviewedFilesWhoseDiffChangedWhileAway() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift", added: 2), changed("b.swift")])
        git.diffs["a.swift"] = d2
        git.diffs["b.swift"] = d1
        let (model, store) = makeReviewModel(git: git)
        var seeded = ReviewRecord(worktree: model.worktree, comparison: GitComparison(base: "main"))
        seeded.files["a.swift"] = FileReview(
            state: .reviewed,
            reviewedDiffHash: ReviewHash.of(d1, file: changed("a.swift"), stamp: nil))
        seeded.files["b.swift"] = FileReview(
            state: .reviewed,
            reviewedDiffHash: ReviewHash.of(d1, file: changed("b.swift"), stamp: nil))
        store.save(seeded)
        store.flush()

        await model.start()
        XCTAssertEqual(model.phase, .ready)
        let a = model.review(for: "a.swift")
        XCTAssertEqual(a.state, .reviewing)
        XCTAssertTrue(a.changedSinceReviewed)
        XCTAssertNil(a.reviewedDiffHash)
        XCTAssertEqual(model.review(for: "b.swift").state, .reviewed)
        XCTAssertFalse(model.review(for: "b.swift").changedSinceReviewed)

        store.flush()
        let saved = store.load(worktree: model.worktree, comparison: GitComparison(base: "main")).record
        XCTAssertEqual(saved.files["a.swift"]?.state, .reviewing)
        XCTAssertEqual(saved.files["a.swift"]?.changedSinceReviewed, true)
        XCTAssertNil(saved.files["a.swift"]?.reviewedDiffHash)
        XCTAssertEqual(saved.files["b.swift"]?.state, .reviewed)
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
