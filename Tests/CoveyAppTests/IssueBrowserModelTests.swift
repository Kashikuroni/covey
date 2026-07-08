import Foundation
import XCTest
@testable import covey

extension GhIssue {
    /// Test-only memberwise init. The custom `Decodable` init suppresses the
    /// synthesized memberwise one, and — since this extension lives in the test
    /// target, a different module from `covey` — direct stored-property
    /// assignment isn't allowed either ("'self' used before 'self.init' call").
    /// So this round-trips through gh's own JSON shape and reuses the existing
    /// `init(from:)`, assigning the fully-built value to `self` in one shot.
    init(number: Int, title: String, body: String, state: String,
         author: String, labels: [GhLabel], updatedAt: Date, url: String) {
        let json: [String: Any] = [
            "number": number,
            "title": title,
            "body": body,
            "state": state,
            "author": ["login": author],
            "labels": labels.map { ["name": $0.name, "color": $0.color] },
            "updatedAt": updatedAt.timeIntervalSince1970,
            "url": url,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self = try! dec.decode(GhIssue.self, from: data)
    }
}

final class IssueBrowserModelTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCachePlan() {
        XCTAssertEqual(cachePlan(fetchedAt: nil, ttl: 120, now: t0), .fetch)
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-60),
                                 ttl: 120, now: t0), .useCached)
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-120),
                                 ttl: 120, now: t0), .useCached)  // boundary = fresh
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-121),
                                 ttl: 120, now: t0), .revalidate)
    }

    func testStaleNoteText() {
        XCTAssertEqual(staleNoteText(fetchedAt: t0.addingTimeInterval(-300), now: t0),
                       "updated 5m ago — refresh failed")
        XCTAssertEqual(staleNoteText(fetchedAt: t0.addingTimeInterval(-30), now: t0),
                       "updated 0m ago — refresh failed")
    }
}

@MainActor
final class IssueBrowserModelFlowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func issue(_ n: Int, _ title: String, open: Bool = true) -> GhIssue {
        GhIssue(number: n, title: title, body: "b", state: open ? "OPEN" : "CLOSED",
                author: "a", labels: [], updatedAt: Date(timeIntervalSince1970: 0),
                url: "https://github.com/o/r/issues/\(n)")
    }

    /// Model with a scripted fetcher; `calls` counts network hits.
    func makeBrowser(result: @escaping () -> GhOutcome<[GhIssue]>,
                     calls: @escaping () -> Void = {},
                     now: Date? = nil) -> IssueBrowserModel {
        let clock = now ?? t0
        return IssueBrowserModel(fetchIssues: { _, _ in
            calls()
            return result()
        }, now: { clock })
    }

    func testOpenFetchesAndCaches() async {
        var count = 0
        let m = makeBrowser(result: { .success([self.issue(1, "one")]) },
                            calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .ready)
        XCTAssertEqual(m.issues.map(\.number), [1])
        XCTAssertEqual(m.selectedNumber, 1)
        XCTAssertEqual(count, 1)
        // Re-open within TTL: cache serves, no second call.
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 1)
    }

    func testOpenFailureWithoutCacheIsFullScreenFailed() async {
        let m = makeBrowser(result: { .failure("boom") })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .failed("boom"))
    }

    func testStaleServesCacheAndRevalidates() async {
        var count = 0
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "one")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in count += 1; return result },
                                  now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        // Fast-forward past the TTL and refetch with fresh data.
        m.now = { self.t0.addingTimeInterval(issueCacheTTL + 1) }
        result = .success([issue(1, "one"), issue(2, "two")])
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 2)                       // revalidated
        XCTAssertEqual(m.issues.count, 2)              // replaced by fresh data
        XCTAssertNil(m.staleNote)
    }

    func testStaleRefetchFailureKeepsCacheWithNote() async {
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "one")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in result }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        m.now = { self.t0.addingTimeInterval(400) }
        result = .failure("offline")
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .ready)                // cache still on screen
        XCTAssertEqual(m.issues.map(\.number), [1])
        XCTAssertEqual(m.staleNote, "updated 6m ago — refresh failed")
    }

    func testSelectionSurvivesListReplacementByNumber() async {
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "a"), issue(2, "b")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in result }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        m.moveSelection(1)
        XCTAssertEqual(m.selectedNumber, 2)
        result = .success([issue(2, "b"), issue(3, "c")])   // #1 vanished
        await m.refresh(force: true)
        XCTAssertEqual(m.selectedNumber, 2)                 // kept by number
        result = .success([issue(9, "z")])                  // #2 vanished too
        await m.refresh(force: true)
        XCTAssertEqual(m.selectedNumber, 9)                 // falls to first
    }

    func testCycleFilterCachesPerFilter() async {
        var count = 0
        let m = makeBrowser(result: { .success([]) }, calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")      // open filter, fetch 1
        await m.cycleFilter()                    // closed, fetch 2
        XCTAssertEqual(m.stateFilter, .closed)
        await m.cycleFilter()                    // all, fetch 3
        await m.cycleFilter()                    // back to open: cached, no fetch
        XCTAssertEqual(m.stateFilter, .open)
        XCTAssertEqual(count, 3)
    }

    func testInvalidateForcesNextFetch() async {
        var count = 0
        let m = makeBrowser(result: { .success([self.issue(1, "a")]) },
                            calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")
        m.invalidate(root: "/r")
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 2)
    }

    func testVisibleAppliesFuzzyQuery() async {
        let m = makeBrowser(result: {
            .success([self.issue(1, "Fix scroll bug"), self.issue(2, "Add themes")])
        })
        await m.open(root: "/r", dir: "/r")
        m.query = "them"
        XCTAssertEqual(m.visible().map(\.number), [2])
        m.query = "#1"
        XCTAssertEqual(m.visible().map(\.number), [1])   // matches "#num title"
        m.query = ""
        XCTAssertEqual(m.visible().count, 2)
    }

    func testMoveSelectionWalksVisibleAndClamps() async {
        let m = makeBrowser(result: {
            .success([self.issue(1, "a"), self.issue(2, "b"), self.issue(3, "c")])
        })
        await m.open(root: "/r", dir: "/r")
        m.moveSelection(1); m.moveSelection(1)
        XCTAssertEqual(m.selectedNumber, 3)
        m.moveSelection(1)                       // clamps at the end
        XCTAssertEqual(m.selectedNumber, 3)
        m.moveSelection(-5)                      // clamps at the start
        XCTAssertEqual(m.selectedNumber, 1)
    }

    func testForcedRefreshTogglesRevalidating() async {
        var observed = false
        var m: IssueBrowserModel!
        m = IssueBrowserModel(fetchIssues: { _, _ in
            observed = m.revalidating
            return .success([self.issue(1, "a")])
        }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")   // first fetch: observed value irrelevant
        observed = false
        await m.refresh(force: true)
        XCTAssertTrue(observed)               // flag was up while the fetch ran
        XCTAssertFalse(m.revalidating)        // and dropped after
    }

    func testOpenPopulatesLocalBranches() async {
        let m = IssueBrowserModel(
            fetchIssues: { _, _ in .success([self.issue(1, "a")]) },
            fetchBranches: { _ in ["main", "12-fix"] },
            now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.localBranches, ["main", "12-fix"])
    }

    func testStaleBranchesDoNotApplyAfterRootSwitch() async {
        // Park /a's branch fetch; open /b; the late /a result must not land.
        var release: CheckedContinuation<Void, Never>?
        let m = IssueBrowserModel(
            fetchIssues: { _, _ in .success([]) },
            fetchBranches: { dir in
                if dir == "/a" {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        release = c
                    }
                    return ["a-late"]
                }
                return ["b-branch"]
            },
            now: { self.t0 })
        async let first: Void = m.open(root: "/a", dir: "/a")
        while release == nil { await Task.yield() }
        await m.open(root: "/b", dir: "/b")
        XCTAssertEqual(m.localBranches, ["b-branch"])
        release?.resume()
        await first
        XCTAssertEqual(m.localBranches, ["b-branch"])   // /a's late result dropped
    }

    func testQueryEditCorrectsHiddenSelection() async {
        let m = IssueBrowserModel(fetchIssues: { _, _ in
            .success([self.issue(1, "alpha"), self.issue(2, "beta")])
        }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.selectedNumber, 1)
        m.query = "beta"                      // #1 no longer visible
        XCTAssertEqual(m.selectedNumber, 2)   // selection snaps to first visible
        m.query = ""
        XCTAssertEqual(m.selectedNumber, 2)   // still valid -> unchanged
    }

    /// C1: a slow revalidate for a root the user has since navigated away
    /// from must not clobber the currently displayed list when it finally
    /// resolves — but its cache entry must still be updated so a later
    /// re-open of that root sees the fresh data without a redundant fetch.
    func testStaleRevalidateDoesNotClobberCurrentRoot() async {
        var aCallCount = 0
        var gate: CheckedContinuation<GhOutcome<[GhIssue]>, Never>?
        let m = IssueBrowserModel(fetchIssues: { dir, _ in
            if dir == "/a" {
                aCallCount += 1
                if aCallCount == 1 {
                    return .success([self.issue(1, "a1")])
                }
                // Second call onward (the revalidate): gate until the test
                // explicitly releases it, simulating an in-flight fetch.
                return await withCheckedContinuation { cont in gate = cont }
            }
            return .success([self.issue(9, "b1")])
        }, now: { self.t0 })

        await m.open(root: "/a", dir: "/a")
        XCTAssertEqual(m.issues.map(\.number), [1])

        // Kick off a slow revalidate for "/a" without waiting for it.
        let refreshTask = Task { await m.refresh(force: true) }
        while gate == nil { await Task.yield() }   // wait until the fetch is gated

        // Navigate to a different root while "/a"'s revalidate is in flight.
        await m.open(root: "/b", dir: "/b")
        XCTAssertEqual(m.root, "/b")
        XCTAssertEqual(m.issues.map(\.number), [9])

        // Release "/a"'s late result.
        gate?.resume(returning: .success([self.issue(1, "a2"), self.issue(2, "a2b")]))
        await refreshTask.value

        // The late "/a" result must not have replaced "/b"'s displayed list.
        XCTAssertEqual(m.root, "/b")
        XCTAssertEqual(m.issues.map(\.number), [9])

        // But "/a"'s cache entry IS updated: re-opening it serves the fresh
        // data from cache, with no additional network call.
        let callsBeforeReopen = aCallCount
        await m.open(root: "/a", dir: "/a")
        XCTAssertEqual(m.issues.map(\.number), [1, 2])
        XCTAssertEqual(aCallCount, callsBeforeReopen)
    }

    /// C1 failure variant: a slow revalidate for a root the user has since
    /// navigated away from finishes with an error, not fresh data. That
    /// failure must not paint the currently displayed root's screen with a
    /// stale note (or otherwise disturb it) — the currency guard in
    /// `fetchInto`'s failure branch must gate this exactly like the success
    /// branch does.
    func testStaleRevalidateFailureDoesNotClobberCurrentRoot() async {
        var aCallCount = 0
        var gate: CheckedContinuation<GhOutcome<[GhIssue]>, Never>?
        let m = IssueBrowserModel(fetchIssues: { dir, _ in
            if dir == "/a" {
                aCallCount += 1
                if aCallCount == 1 {
                    return .success([self.issue(1, "a1")])
                }
                // Second call onward (the revalidate): gate until the test
                // explicitly releases it, simulating an in-flight fetch.
                return await withCheckedContinuation { cont in gate = cont }
            }
            return .success([self.issue(9, "b1")])
        }, now: { self.t0 })

        await m.open(root: "/a", dir: "/a")
        XCTAssertEqual(m.issues.map(\.number), [1])

        // Kick off a slow revalidate for "/a" without waiting for it.
        let refreshTask = Task { await m.refresh(force: true) }
        while gate == nil { await Task.yield() }   // wait until the fetch is gated

        // Navigate to a different root while "/a"'s revalidate is in flight.
        await m.open(root: "/b", dir: "/b")
        XCTAssertEqual(m.root, "/b")
        XCTAssertEqual(m.issues.map(\.number), [9])

        // Release "/a"'s late result — as a failure this time.
        gate?.resume(returning: .failure("late error"))
        await refreshTask.value

        // The late "/a" failure must not have replaced "/b"'s displayed list,
        // flipped its stage, or painted it with a stale note meant for "/a".
        XCTAssertEqual(m.root, "/b")
        XCTAssertEqual(m.issues.map(\.number), [9])
        XCTAssertEqual(m.stage, .ready)
        XCTAssertNil(m.staleNote)
    }
}

@MainActor
final class IssueBrowserModelActionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func issue(_ n: Int, open: Bool = true) -> GhIssue {
        GhIssue(number: n, title: "t\(n)", body: "b", state: open ? "OPEN" : "CLOSED",
                author: "a", labels: [], updatedAt: Date(timeIntervalSince1970: 0),
                url: "https://github.com/o/r/issues/\(n)")
    }

    struct Recorder {
        var mutations: [[String]] = []
        var toasts: [String] = []
        var fetchCount = 0
    }

    /// Browser over one scripted issue list; mutations recorded, not run.
    func makeBrowser(_ issues: [GhIssue],
                     mutationError: String? = nil) async
        -> (IssueBrowserModel, () -> Recorder) {
        var recorder = Recorder()
        let m = IssueBrowserModel(
            fetchIssues: { _, _ in recorder.fetchCount += 1; return .success(issues) },
            fetchLabels: { _ in .success([GhLabel(name: "bug", color: "d73a4a")]) },
            runMutation: { args, _ in recorder.mutations.append(args); return mutationError },
            toast: { recorder.toasts.append($0) },
            now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        return (m, { recorder })
    }

    func testLabelsLoadOnce() async {
        let (m, _) = await makeBrowser([issue(1)])
        await m.loadLabelsIfNeeded()
        XCTAssertEqual(m.labels?.map(\.name), ["bug"])
        await m.loadLabelsIfNeeded()          // second call is a no-op
        XCTAssertEqual(m.labels?.count, 1)
    }

    func testCloseFlow() async {
        let (m, rec) = await makeBrowser([issue(1)])
        m.beginClose()
        XCTAssertEqual(m.prompt, .closeReason(1))
        await m.closeSelected(reason: .notPlanned)
        XCTAssertNil(m.prompt)
        XCTAssertEqual(rec().mutations,
                       [["gh", "issue", "close", "1", "--reason", "not planned"]])
        XCTAssertEqual(rec().toasts, ["issue #1 closed"])
        XCTAssertEqual(rec().fetchCount, 2)   // open + post-mutation refetch
    }

    func testBeginCloseOnClosedIssueReopensInstead() async {
        let (m, rec) = await makeBrowser([issue(2, open: false)])
        m.beginClose()
        XCTAssertNil(m.prompt)                // no reason prompt for reopen
        await m.reopenSelected()
        XCTAssertEqual(rec().mutations, [["gh", "issue", "reopen", "2"]])
        XCTAssertEqual(rec().toasts, ["issue #2 reopened"])
    }

    func testDeleteFlow() async {
        let (m, rec) = await makeBrowser([issue(3)])
        m.screen = .detail(3)
        m.beginDelete()
        XCTAssertEqual(m.prompt, .deleteConfirm(3))
        await m.deleteConfirmed()
        XCTAssertEqual(rec().mutations, [["gh", "issue", "delete", "3", "--yes"]])
        XCTAssertEqual(rec().toasts, ["issue #3 deleted"])
        XCTAssertEqual(m.screen, .list)       // deleted from detail -> back to list
    }

    func testMutationErrorToastsAndKeepsScreen() async {
        let (m, rec) = await makeBrowser([issue(1)], mutationError: "admin only")
        m.beginDelete()
        await m.deleteConfirmed()
        XCTAssertEqual(rec().toasts, ["admin only"])
        XCTAssertEqual(rec().fetchCount, 1)   // failed mutation: no refetch
        XCTAssertFalse(m.actionBusy)
    }

    func testSaveEdit() async {
        let (m, rec) = await makeBrowser([issue(1)])
        let ok = await m.saveEdit(number: 1, title: "new", body: nil,
                                  addLabels: ["bug"], removeLabels: [])
        XCTAssertTrue(ok)
        XCTAssertEqual(rec().mutations,
                       [["gh", "issue", "edit", "1", "--title", "new",
                         "--add-label", "bug"]])
        XCTAssertEqual(rec().toasts, ["issue #1 updated"])
    }

    func testSaveEditNoChangesSkipsGh() async {
        let (m, rec) = await makeBrowser([issue(1)])
        let ok = await m.saveEdit(number: 1, title: nil, body: nil,
                                  addLabels: [], removeLabels: [])
        XCTAssertTrue(ok)
        XCTAssertTrue(rec().mutations.isEmpty)
    }

    func testCancelPrompt() async {
        let (m, _) = await makeBrowser([issue(1)])
        m.beginDelete()
        m.cancelPrompt()
        XCTAssertNil(m.prompt)
    }
}
