import XCTest
import CoveyGit
@testable import covey

@MainActor
final class ReviewModelCoreTests: XCTestCase {
    func testStartOpensTheDefaultBaseAndSeedsUnreadFiles() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift"), changed("b.swift")])
        let (model, store) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.branchLabel, "feat/x")
        XCTAssertEqual(model.record.comparison, GitComparison(base: "main"))
        XCTAssertEqual(model.review(for: "a.swift").state, .unread)
        XCTAssertEqual(model.record.targetSession, "origin")
        XCTAssertEqual(store.lastComparison(worktree: model.worktree), GitComparison(base: "main"))
    }

    func testStartReusesTheLastComparison() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, store) = makeReviewModel(git: git)
        let last = GitComparison(base: "dev", head: .ref("feat"))
        store.setLastComparison(last, worktree: model.worktree)
        await model.start()
        XCTAssertEqual(model.record.comparison, last)
    }

    func testStartWithoutAnyBaseAsksForAComparison() async {
        let git = FakeReviewGit()
        git.base = nil
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .needsComparison(error: nil))
        XCTAssertTrue(model.comparisonPopoverOpen)
    }

    func testNonRepositoryIsAMissingWorktree() async {
        let git = FakeReviewGit()
        git.label = nil
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .missingWorktree)
    }

    func testUnknownBaseReopensTheComparisonWithTheError() async {
        let git = FakeReviewGit()   // state nil → unknownRef
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .needsComparison(error: "unknown revision 'main'"))
        XCTAssertTrue(model.comparisonPopoverOpen)
    }

    func testSelectingMarksUnreadAsReviewingAndLoadsTheDiff() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 1, "x")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        XCTAssertTrue(model.diffOpen)
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewing)
        XCTAssertEqual(model.diff, .loaded(git.diffs["a.swift"]!))
    }

    func testToggleReviewedStoresAHashAndCountsProgress() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift"), changed("b.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 1, "x")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        await model.toggleReviewed()
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewed)
        XCTAssertEqual(model.review(for: "a.swift").reviewedDiffHash,
                       ReviewHash.of(git.diffs["a.swift"]!, file: changed("a.swift"), stamp: nil))
        XCTAssertEqual(model.reviewedCount, 1)
        XCTAssertEqual(model.progressFraction, 0.5)
        await model.toggleReviewed()
        XCTAssertEqual(model.review(for: "a.swift").state, .reviewing)
        XCTAssertNil(model.review(for: "a.swift").reviewedDiffHash)
    }

    func testJAndKFollowTreeOrderFiltersAndWrap() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("z.txt"), changed("src/b.swift"), changed("src/a.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        var visited: [String?] = []
        for step in [1, 1, 1, 1, -1] {
            await model.nextFile(step)
            visited.append(model.selectedPath)
        }
        XCTAssertEqual(visited, ["src/a.swift", "src/b.swift", "z.txt", "src/a.swift", "z.txt"])
        model.filter.query = "src"
        await model.nextFile(1)
        XCTAssertEqual(model.selectedPath, "src/a.swift", "an unfiltered selection restarts at the top")
    }

    func testNextUnreviewedSkipsReviewedFilesAndSaysWhenDone() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift"), changed("b.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        await model.toggleReviewed()
        await model.nextUnreviewed()
        XCTAssertEqual(model.selectedPath, "b.swift")
        await model.toggleReviewed()
        await model.nextUnreviewed()
        XCTAssertEqual(model.selectedPath, "b.swift")
        XCTAssertEqual(model.toasts.last?.text, "Everything is reviewed")
    }

    func testEmptyComparisonIsSafe() async {
        let git = FakeReviewGit()
        git.state = comparisonState([])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.progressFraction, 0)
        await model.nextFile(1)
        await model.nextUnreviewed()
        model.jumpStop(1)
        model.setCanvasViewport(CGSize(width: 800, height: 600))
        model.fitCanvas()
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.canvas, CanvasTransform())
        XCTAssertEqual(model.stopLabel, "0/0")
    }

    func testBigAndUncountedDiffsStayCollapsedUntilLoadAnyway() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("big.swift", added: 6000, removed: 10),
                                     changed("huge.log", .added, added: nil, removed: nil, untracked: true)])
        git.diffs["big.swift"] = oneHunk([(.added, nil, 1, "x")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("big.swift")
        XCTAssertEqual(model.diff, .tooLarge(lines: 6010))
        XCTAssertEqual(git.diffCalls, 0)
        await model.loadAnyway()
        XCTAssertEqual(model.diff, .loaded(git.diffs["big.swift"]!))
        await model.select("huge.log")
        XCTAssertEqual(model.diff, .tooLarge(lines: nil))
    }

    func testBinaryAndFailedDiffs() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("bin.dat", added: nil, removed: nil, binary: true),
                                     changed("slow.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("bin.dat")
        XCTAssertEqual(model.diff, .binary)
        git.diffError = GitError(kind: .timedOut, description: "git diff timed out after 10s")
        await model.select("slow.swift")
        XCTAssertEqual(model.diff, .failed("Diff too large or timed out"))
    }

    func testChangeStopsNavigateAndWrap() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.context, 1, 1, "a"), (.removed, 2, nil, "b"), (.added, nil, 2, "B"),
                                        (.context, 3, 3, "c"), (.added, nil, 4, "d")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        XCTAssertEqual(model.stopLabel, "1/2")
        model.jumpStop(1)
        XCTAssertEqual(model.stopLabel, "2/2")
        XCTAssertEqual(model.scrollRequest?.rowID, "h0-l4")
        model.jumpStop(1)
        XCTAssertEqual(model.stopLabel, "1/2")
        XCTAssertEqual(model.scrollRequest?.rowID, "h0-l1")
    }

    func testFullFileTogglesTheFetch() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 5, "x")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "top"), (.added, nil, 2, "x")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        await model.toggleFullFile()
        XCTAssertTrue(model.fullFile)
        XCTAssertEqual(model.diff, .loaded(git.fullDiffs["a.swift"]!))
        await model.toggleFullFile()
        XCTAssertEqual(model.diff, .loaded(git.diffs["a.swift"]!))
    }

    func testReviewSurvivesReopening() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (first, store) = makeReviewModel(git: git)
        await first.start()
        await first.select("a.swift")
        await first.toggleReviewed()
        first.flush()
        let (second, _) = makeReviewModel(git: git, store: store)
        await second.start()
        XCTAssertEqual(second.review(for: "a.swift").state, .reviewed)
    }

    func testEscapeUnwindsInOrder() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        await model.toggleFullFile()
        model.comparisonPopoverOpen = true
        model.composer = ReviewComposer(anchor: LineAnchor(path: "a.swift", side: .new, line: 1, lineText: ""))
        model.keysOverlayOpen = true

        await model.escape()
        XCTAssertFalse(model.keysOverlayOpen)
        await model.escape()
        XCTAssertNil(model.composer)
        await model.escape()
        XCTAssertFalse(model.comparisonPopoverOpen)
        await model.escape()
        XCTAssertFalse(model.fullFile)
        await model.escape()
        XCTAssertFalse(model.diffOpen)
    }

    // MARK: - Stale loads

    func testSwitchingComparisonMidLoadKeepsTheNewOne() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("main.swift")])
        git.statesByBase["a"] = comparisonState([changed("only-a.swift")], fingerprint: "fp-a")
        git.statesByBase["b"] = comparisonState([changed("only-b.swift")], fingerprint: "fp-b")
        let (model, store) = makeReviewModel(git: git)
        await model.start()
        let b = GitComparison(base: "b")

        let held = git.holdNextChanges(base: "a")
        let slowA = Task { await model.open(GitComparison(base: "a")) }
        await held.waitUntilArrived()
        await model.open(b)
        XCTAssertEqual(model.files.map(\.path), ["only-b.swift"])
        XCTAssertFalse(model.comparisonPopoverOpen)
        // The abandoned load must not touch anything, so a reopened popover stays open.
        model.comparisonPopoverOpen = true

        held.release()
        await slowA.value
        XCTAssertEqual(model.record.comparison, b)
        XCTAssertEqual(model.files.map(\.path), ["only-b.swift"])
        XCTAssertEqual(model.state?.fingerprint, "fp-b")
        XCTAssertEqual(Set(model.record.files.keys), ["only-b.swift"])
        XCTAssertEqual(store.lastComparison(worktree: model.worktree), b)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.comparisonPopoverOpen)
    }

    /// Switching clears the old state at once; until the new one lands the
    /// review is loading — not an empty, ready comparison that a poll may reload.
    func testOpenIsLoadingUntilTheChangesArrive() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("main.swift")])
        git.statesByBase["b"] = comparisonState([changed("only-b.swift")], fingerprint: "fp-b")
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.phase, .ready)

        let held = git.holdNextChanges(base: "b")
        let switching = Task { await model.open(GitComparison(base: "b")) }
        await held.waitUntilArrived()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.state)
        await model.checkFreshness()
        XCTAssertEqual(git.fingerprintCalls, 0)

        held.release()
        await switching.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.files.map(\.path), ["only-b.swift"])
    }

    func testLateFailureOfAnAbandonedLoadIsIgnored() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("main.swift")])
        git.statesByBase["b"] = comparisonState([changed("only-b.swift")])
        let (model, store) = makeReviewModel(git: git)
        await model.start()
        let b = GitComparison(base: "b")

        let held = git.holdNextChanges(base: "a")
        let slowA = Task { await model.open(GitComparison(base: "a")) }
        await held.waitUntilArrived()
        await model.open(b)

        held.release(throwing: GitError(kind: .unknownRef("a"), description: "unknown revision 'a'"))
        await slowA.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.comparisonPopoverOpen)
        XCTAssertEqual(model.record.comparison, b)
        XCTAssertEqual(model.files.map(\.path), ["only-b.swift"])
        XCTAssertEqual(store.lastComparison(worktree: model.worktree), b)
    }

    func testStaleFullFileResultDoesNotOverwriteHunks() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 5, "hunk")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "top"), (.added, nil, 2, "full")])
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")

        let held = git.holdNextDiff(fullFile: true)
        let slowFull = Task { await model.toggleFullFile() }
        await held.waitUntilArrived()
        XCTAssertTrue(model.fullFile)
        await model.toggleFullFile()
        XCTAssertFalse(model.fullFile)
        XCTAssertEqual(model.diff, .loaded(git.diffs["a.swift"]!))

        held.release()
        await slowFull.value
        XCTAssertFalse(model.fullFile)
        XCTAssertEqual(model.diff, .loaded(git.diffs["a.swift"]!))
    }

    func testToggleReviewedAcrossAComparisonSwitchWritesNothing() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.statesByBase["other"] = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 1, "x")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "top"), (.added, nil, 2, "x")])
        let (model, store) = makeReviewModel(git: git)
        await model.start()
        await model.select("a.swift")
        await model.toggleFullFile()   // full-file mode skips currentHash's fast path
        let other = GitComparison(base: "other")

        let held = git.holdNextDiff(fullFile: false)
        let slowToggle = Task { await model.toggleReviewed() }
        await held.waitUntilArrived()
        await model.open(other)

        held.release()
        await slowToggle.value
        XCTAssertEqual(model.record.comparison, other)
        XCTAssertNotEqual(model.review(for: "a.swift").state, .reviewed)
        XCTAssertNil(model.review(for: "a.swift").reviewedDiffHash)
        store.flush()
        let saved = store.load(worktree: model.worktree, comparison: other).record
        XCTAssertNotEqual(saved.files["a.swift"]?.state, .reviewed)
    }

    func testServiceReadsARealRepository() async throws {
        let repo = "\(NSTemporaryDirectory())covey-review-repo-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let script = "mkdir -p '\(repo)' && git -C '\(repo)' init -q -b main && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && echo hi > '\(repo)/new.txt'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let service = ReviewGitService()
        let label = await service.branchLabel(worktree: repo)
        XCTAssertEqual(label, "main")
        let state = try await service.changes(worktree: repo, comparison: GitComparison(base: "main"))
        XCTAssertEqual(state.files.map(\.path), ["new.txt"])
        XCTAssertEqual(state.files.first?.isUntracked, true)
    }
}
