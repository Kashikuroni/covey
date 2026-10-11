import XCTest
import CoveyGit
@testable import covey

final class ReviewModelOpsTests: XCTestCase {
    func testServiceStageAndIndexRoundTripThroughRealRepository() async throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "two\n")

        let service = ReviewGitService()
        let before = try await service.indexStatus(worktree: repo.path)
        XCTAssertFalse(try XCTUnwrap(before.first { $0.path == "a.txt" }).staged)

        try await service.stage(worktree: repo.path, paths: ["a.txt"])
        let after = try await service.indexStatus(worktree: repo.path)
        XCTAssertTrue(try XCTUnwrap(after.first { $0.path == "a.txt" }).staged)
    }
}

@MainActor
final class ReviewModelOpsFlowTests: XCTestCase {
    private func makeModel(_ files: [ChangedFile]) async -> (ReviewModel, FakeReviewGit) {
        let git = FakeReviewGit()
        git.state = comparisonState(files)
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        return (model, git)
    }

    func testStageThenUnstageUpdatesIndexStateAndCallsGit() async {
        let (model, git) = await makeModel([changed("a.swift"), changed("b.swift")])
        await model.setStaged("a.swift", true)
        XCTAssertEqual(git.stageCalls, [["a.swift"]])
        XCTAssertEqual(model.indexState["a.swift"], true)

        await model.setStaged("a.swift", false)
        XCTAssertEqual(git.unstageCalls, [["a.swift"]])
        XCTAssertEqual(model.indexState["a.swift"], false)
    }

    func testStaleTreeRefreshesBeforeStaging() async {          // Review Focus 1
        let (model, git) = await makeModel([changed("a.swift")])
        git.fingerprintValue = "moved-on"                        // ≠ the state's "fp-1"
        git.state = comparisonState([changed("a.swift"), changed("new.swift")])

        await model.setStaged("a.swift", true)

        XCTAssertGreaterThanOrEqual(git.changesCalls, 2)         // reloaded first
        XCTAssertEqual(git.stageCalls, [["a.swift"]])            // then staged once
        XCTAssertEqual(model.banner, "Tree changed — refreshed before staging")
    }

    func testStageAllAndUnstageAll() async {
        let (model, git) = await makeModel([changed("a.swift")])
        await model.stageAllChanges()
        XCTAssertEqual(git.stageAllCalls, 1)
        await model.unstageAllChanges()
        XCTAssertEqual(git.unstageAllCalls, 1)
    }

    func testBeginCommitNeedsStagedFiles() async {
        let (model, _) = await makeModel([changed("a.swift")])
        model.beginCommit()
        XCTAssertFalse(model.commitSheetOpen)                    // nothing staged yet

        model.indexState = ["a.swift": true]
        model.beginCommit()
        XCTAssertTrue(model.commitSheetOpen)
        model.cancelCommit()
        XCTAssertFalse(model.commitSheetOpen)
    }

    func testCommitSuccessClosesSheetAndReloads() async {
        let (model, git) = await makeModel([changed("a.swift")])
        model.indexState = ["a.swift": true]
        model.beginCommit()

        await model.commit(summary: "add a", body: "with body")

        XCTAssertEqual(git.commitCalls.count, 1)
        XCTAssertEqual(git.commitCalls[0].summary, "add a")
        XCTAssertNil(model.commitError)
        XCTAssertFalse(model.commitSheetOpen)
        XCTAssertGreaterThanOrEqual(git.changesCalls, 2)         // reload happened
    }

    func testCommitErrorStaysInSheet() async {
        let (model, git) = await makeModel([changed("a.swift")])
        git.commitError = GitError("hook says no")
        model.indexState = ["a.swift": true]
        model.beginCommit()

        await model.commit(summary: "blocked", body: "")

        XCTAssertEqual(git.commitCalls.count, 1)
        XCTAssertEqual(model.commitError, "hook says no")
        XCTAssertTrue(model.commitSheetOpen)
    }

    func testPushWithoutUpstreamAsksThenPublishes() async {
        let (model, git) = await makeModel([changed("a.swift")])
        git.upstream = nil

        await model.push()
        XCTAssertTrue(git.pushCalls.isEmpty)                      // first click only arms
        XCTAssertTrue(model.pushUpstreamPending)

        await model.push()
        XCTAssertEqual(git.pushCalls.count, 1)
        XCTAssertEqual(git.pushCalls[0].remote, "origin")
        XCTAssertEqual(git.pushCalls[0].setUpstream, true)
        XCTAssertFalse(model.pushUpstreamPending)
    }

    func testPushWithUpstreamFetchesAndRefreshes() async throws {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        // Set before start(): open() refreshes model.upstream from the fake.
        git.upstream = UpstreamInfo(remote: "origin", branch: "feat/x", ahead: 2, behind: 0)
        let (model, _) = makeReviewModel(git: git)
        await model.start()
        XCTAssertEqual(model.upstream?.ahead, 2)

        await model.push()

        let push = try XCTUnwrap(git.pushCalls.first)
        XCTAssertEqual(push.remote, "origin")
        XCTAssertEqual(push.setUpstream, false)
        XCTAssertEqual(git.fetchCalls, ["origin"])
        XCTAssertEqual(model.upstream?.ahead, 0)                  // refreshed after push
    }

    func testToggleStagedFocusedUsesSelection() async {
        let (model, git) = await makeModel([changed("a.swift")])
        await model.select("a.swift")
        await model.toggleStagedFocused()
        XCTAssertEqual(git.stageCalls, [["a.swift"]])
    }

    func testEscapeClosesCommitSheetFirst() async {
        let (model, _) = await makeModel([changed("a.swift")])
        model.indexState = ["a.swift": true]
        model.beginCommit()
        await model.escape()
        XCTAssertFalse(model.commitSheetOpen)
    }

    func testCommitDuringFreshnessCheckDoesNotDoubleCommit() async {   // review fix 1
        let (model, git) = await makeModel([changed("a.swift")])
        model.indexState = ["a.swift": true]
        let gate = git.holdNextFingerprint()      // parks the first commit in ensureFresh
        let first = Task { await model.commit(summary: "one", body: "") }
        await gate.waitUntilArrived()

        // The fix's observable: the busy flag is hoisted above the freshness
        // await, so a second click mid-check sees committing == true and bails.
        XCTAssertTrue(model.committing)
        await model.commit(summary: "two", body: "")
        XCTAssertEqual(git.commitCalls.count, 0)

        gate.release()
        for _ in 0..<200 {                                          // let the parked task drain
            if !git.commitCalls.isEmpty { break }
            await Task.yield()
        }
        await first
        XCTAssertEqual(git.commitCalls.count, 1)
        XCTAssertEqual(git.commitCalls.first?.summary, "one")
    }

    func testStagedPathMissingFromComparisonStillCounts() async {      // review fix 2
        let (model, _) = await makeModel([changed("a.swift")])
        // "reverted.txt" is staged but its worktree content matches the base,
        // so the base↔worktree comparison does not list it. Git commits it.
        model.indexState = ["reverted.txt": true]

        XCTAssertTrue(model.hasStaged)
        XCTAssertEqual(model.stagedPaths, ["reverted.txt"])
    }
}
