import XCTest
import CoveyGit
import CoveyKit
@testable import covey

@MainActor
final class ReviewModelAnnotationTests: XCTestCase {
    private var directory: FakeDirectory!

    /// a.swift with a two-line diff, selected; `origin` is a live target in the worktree.
    private func loadedModel(_ git: FakeReviewGit = FakeReviewGit(),
                             store: ReviewStore? = nil) async -> (ReviewModel, FakeReviewGit, ReviewStore) {
        if git.state == nil {
            git.state = comparisonState([changed("a.swift")])
            git.diffs["a.swift"] = oneHunk([(.context, 1, 1, "import A"), (.added, nil, 2, "let x = 1")])
        }
        directory = FakeDirectory()
        directory.targets = [ReviewTarget(name: "origin", dir: NSTemporaryDirectory(), agent: "claude", status: .idle)]
        let (model, usedStore) = makeReviewModel(git: git, directory: directory, store: store)
        await model.start()
        await model.select("a.swift")
        return (model, git, usedStore)
    }

    private func anchor(_ path: String = "a.swift", _ line: Int = 2, _ text: String = "let x = 1",
                        side: ReviewSide = .new) -> LineAnchor {
        LineAnchor(path: path, side: side, line: line, lineText: text)
    }

    func testIssueAndCommentCreation() async {
        let (model, _, _) = await loadedModel()
        model.openComposer(side: .new, line: 2, text: "let x = 1")
        model.composer?.draft = "  First line\nmore detail  "
        model.composer?.severity = .high
        model.submitIssue()
        XCTAssertNil(model.composer)
        XCTAssertEqual(model.record.issues.count, 1)
        let issue = model.record.issues[0]
        XCTAssertEqual(issue.id, 1)
        XCTAssertEqual(issue.title, "First line")
        XCTAssertEqual(issue.body, "First line\nmore detail")
        XCTAssertEqual(issue.severity, .high)
        XCTAssertEqual(issue.status, .open)
        XCTAssertEqual(issue.anchor, anchor())
        XCTAssertEqual(model.record.nextIssueId, 2)
        XCTAssertTrue(model.hasOpenIssues("a.swift"))
        XCTAssertEqual(model.toasts.last?.text, "Issue #1 created")

        model.openComposer(side: .new, line: 1, text: "import A")
        model.composer?.draft = "why?"
        model.submitComment()
        XCTAssertEqual(model.record.comments.map(\.text), ["why?"])

        // The prompt builder splits on "\n"; a CRLF draft must not carry "\r" into it.
        model.openComposer(side: .new, line: 1, text: "import A")
        model.composer?.draft = "a\r\nb"
        model.submitComment()
        XCTAssertEqual(model.record.comments.last?.text, "a\nb")
        model.openComposer(side: .new, line: 1, text: "import A")
        model.composer?.draft = "a\r\nb"
        model.submitIssue()
        XCTAssertEqual(model.record.issues.last?.body, "a\nb")
    }

    func testBlankDraftCreatesNothing() async {
        let (model, _, _) = await loadedModel()
        model.openComposer(side: .new, line: 2, text: "let x = 1")
        model.composer?.draft = "  \n "
        model.submitIssue()
        model.submitComment()
        XCTAssertTrue(model.record.issues.isEmpty)
        XCTAssertTrue(model.record.comments.isEmpty)
        XCTAssertNotNil(model.composer)
    }

    func testComposeAtCurrentStopAnchorsTheFirstChangedLine() async {
        let (model, _, _) = await loadedModel()
        model.composeAtCurrentStop()
        XCTAssertEqual(model.composer?.anchor, anchor())
    }

    func testIssueStatusChangesDriveTheOpenFilter() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "t", body: "t", severity: .low,
                                           status: .open, createdAt: Date())]
        model.setStatus(.resolved, forIssue: 1)
        XCTAssertFalse(model.hasOpenIssues("a.swift"))
        XCTAssertTrue(model.visibleIssues.isEmpty)
        model.issueFilter = .all
        XCTAssertEqual(model.visibleIssues.map(\.id), [1])
    }

    func testThreadsGroupBySideAndLineAndHideLostAnchors() async {
        let (model, _, _) = await loadedModel()
        let comment = ReviewComment(id: UUID(), anchor: anchor(), text: "c", createdAt: Date())
        var lost = ReviewIssue(id: 2, anchor: anchor("a.swift", 9, "gone"), title: "lost", body: "lost",
                               severity: .low, status: .open, createdAt: Date())
        lost.anchorState = .outdated
        let old = ReviewIssue(id: 3, anchor: anchor("a.swift", 2, "old", side: .old), title: "o", body: "o",
                              severity: .low, status: .open, createdAt: Date())
        model.record.comments = [comment]
        model.record.issues = [lost, old]
        let threads = model.threads(for: "a.swift")
        XCTAssertEqual(threads[ThreadKey(side: .new, line: 2)]?.map(\.id), ["c-\(comment.id.uuidString)"])
        XCTAssertEqual(threads[ThreadKey(side: .old, line: 2)]?.map(\.id), ["i-3"])
        XCTAssertEqual(model.outdatedItems(for: "a.swift").map(\.id), ["i-2"])
    }

    func testAnchorsAreRecheckedWhenTheReviewOpens() async {
        let store = ReviewStore(root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))", debounce: 0)
        var record = ReviewRecord(worktree: NSTemporaryDirectory(), comparison: GitComparison(base: "main"))
        record.comments = [ReviewComment(id: UUID(), anchor: anchor("a.swift", 5, "moved()"), text: "m", createdAt: Date())]
        record.issues = [
            ReviewIssue(id: 1, anchor: anchor("a.swift", 3, "gone()"), title: "g", body: "g", severity: .low, status: .open, createdAt: Date()),
            ReviewIssue(id: 2, anchor: anchor("left.swift", 1, "x"), title: "l", body: "l", severity: .low, status: .open, createdAt: Date()),
        ]
        store.save(record)
        store.flush()

        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "a"), (.added, nil, 7, "moved()")])
        let (model, _, _) = await loadedModel(git, store: store)

        XCTAssertEqual(model.record.comments[0].anchorState, .tracked)
        XCTAssertEqual(model.record.comments[0].anchor.line, 7)
        XCTAssertEqual(model.record.comments[0].note, "Tracked :5 → :7")
        XCTAssertEqual(model.record.issues[0].anchorState, .outdated)
        XCTAssertEqual(model.record.issues[1].anchorState, .fileGone)
        XCTAssertEqual(model.record.issues[1].note, "File no longer changed")
    }

    func testAnchorRecheckAcrossAComparisonSwitchWritesNothing() async {
        let store = ReviewStore(root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))", debounce: 0)
        let a = GitComparison(base: "a")
        let b = GitComparison(base: "b")
        var recordA = ReviewRecord(worktree: NSTemporaryDirectory(), comparison: a)
        recordA.comments = [ReviewComment(id: UUID(), anchor: anchor("a.swift", 5, "moved()"), text: "a", createdAt: Date())]
        var recordB = ReviewRecord(worktree: NSTemporaryDirectory(), comparison: b)
        recordB.comments = [ReviewComment(id: UUID(), anchor: anchor(), text: "b", createdAt: Date())]
        store.save(recordA)
        store.save(recordB)
        store.flush()

        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "import A"), (.added, nil, 2, "let x = 1")])
        let (model, _) = makeReviewModel(git: git, directory: FakeDirectory(), store: store)
        await model.start()

        let held = git.holdNextDiff(fullFile: true)
        let slowA = Task { await model.open(a) }
        await held.waitUntilArrived()
        await model.open(b)
        XCTAssertEqual(model.record.comparison, b)
        XCTAssertEqual(model.record.comments[0].anchorState, .current)

        // a's late answer describes a file in which b's line has moved.
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "import A"), (.added, nil, 7, "let x = 1")])
        held.release()
        await slowA.value
        XCTAssertEqual(model.record.comparison, b)
        XCTAssertEqual(model.record.comments[0].anchor, anchor())
        XCTAssertEqual(model.record.comments[0].anchorState, .current)
        XCTAssertNil(model.record.comments[0].note)
        // The abandoned open must not finish as if it were current either.
        XCTAssertEqual(store.lastComparison(worktree: model.worktree), b)
    }

    func testAnchorRecheckLeavesAnchorsAloneWhenTheDiffFails() async {
        let (model, git, _) = await loadedModel()
        model.record.comments = [ReviewComment(id: UUID(), anchor: anchor("a.swift", 99, "nowhere"), text: "c", createdAt: Date())]
        git.diffError = GitError(kind: .timedOut, description: "timed out")
        await model.recheckAnchors()
        XCTAssertEqual(model.record.comments[0].anchorState, .current)
    }

    func testBatchSendPicksOpenIssuesAndUnsentComments() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [
            ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date()),
            ReviewIssue(id: 2, anchor: anchor(), title: "b", body: "b", severity: .low, status: .inProgress, createdAt: Date()),
            ReviewIssue(id: 3, anchor: anchor(), title: "c", body: "c", severity: .low, status: .resolved, createdAt: Date()),
        ]
        let unsent = ReviewComment(id: UUID(), anchor: anchor(), text: "new", createdAt: Date())
        var sent = ReviewComment(id: UUID(), anchor: anchor(), text: "old", createdAt: Date())
        sent.sentAt = Date()
        model.record.comments = [unsent, sent]
        XCTAssertEqual(model.unsentCount, 2)

        model.beginSend()
        XCTAssertEqual(model.sendDraft?.issueIDs, [1])
        XCTAssertEqual(model.sendDraft?.commentIDs, [unsent.id])
        XCTAssertEqual(model.sendDraft?.target, "origin")
    }

    func testPerIssueSendPicksOnlyThatIssue() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [
            ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date()),
            ReviewIssue(id: 2, anchor: anchor(), title: "b", body: "b", severity: .low, status: .open, createdAt: Date()),
        ]
        model.record.comments = [ReviewComment(id: UUID(), anchor: anchor(), text: "c", createdAt: Date())]
        model.beginSend(issue: 2)
        XCTAssertEqual(model.sendDraft?.candidateIssueIDs, [2])
        XCTAssertEqual(model.sendDraft?.commentIDs, [])
    }

    func testSendDeliversAndMarksItems() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date())]
        model.record.comments = [ReviewComment(id: UUID(), anchor: anchor(), text: "c", createdAt: Date())]
        model.beginSend()
        let preview = model.sendPreview
        XCTAssertTrue(model.canSend)
        await model.send()

        XCTAssertEqual(directory.sent.map(\.name), ["origin", "origin"])
        XCTAssertEqual(directory.sent[0].bytes, ReviewSender.pastePayload(preview))
        XCTAssertEqual(directory.sent[1].bytes, ReviewSender.enter)
        XCTAssertEqual(model.record.issues[0].status, .inProgress)
        XCTAssertEqual(model.record.issues[0].sentTo, "origin")
        XCTAssertNotNil(model.record.comments[0].sentAt)
        XCTAssertNil(model.sendDraft)
        XCTAssertEqual(model.toasts.last?.text, "Sent to origin · ⌥⌘R to watch")
        XCTAssertEqual(directory.delivered, ["origin"], "the app hears where to watch")
        XCTAssertEqual(model.unsentCount, 0)
    }

    func testSendFailureMarksNothing() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date())]
        model.beginSend()
        directory.failure = FakeSendError()
        await model.send()
        XCTAssertEqual(model.sendError, "Couldn't send to origin: session is gone")
        XCTAssertEqual(model.record.issues[0].status, .open)
        XCTAssertNil(model.record.issues[0].sentAt)
        XCTAssertNotNil(model.sendDraft)
        XCTAssertEqual(directory.delivered, [], "nothing to watch")
    }

    func testSendWarningsForBusyAgentAndOtherWorktree() async {
        let (model, _, _) = await loadedModel()
        directory.targets = [ReviewTarget(name: "origin", dir: "/elsewhere", agent: "claude", status: .running)]
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date())]
        model.beginSend()
        XCTAssertEqual(model.sendWarnings, [
            "origin is running — the message will be queued.",
            "origin works in /elsewhere; paths in the prompt are relative to \(model.worktree).",
        ])
    }

    func testVanishedTargetBlocksSending() async {
        let (model, _, _) = await loadedModel()
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date())]
        model.setTarget("ghost")
        model.beginSend()
        XCTAssertNil(model.target)
        XCTAssertFalse(model.canSend)
        model.setTarget("origin")
        XCTAssertTrue(model.canSend)
    }

    /// `.waiting` = a selection/permission prompt is on screen: paste + Enter
    /// would answer it (e.g. approve a tool call), so nothing may be sent.
    func testWaitingTargetBlocksSendingUntilItIsIdle() async {
        let (model, _, _) = await loadedModel()
        directory.targets = [ReviewTarget(name: "origin", dir: NSTemporaryDirectory(), agent: "claude", status: .waiting)]
        model.record.issues = [ReviewIssue(id: 1, anchor: anchor(), title: "a", body: "a", severity: .low, status: .open, createdAt: Date())]
        model.beginSend()
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.sendWarnings, ["origin is waiting on a prompt — answer it in the session first."])

        await model.send()
        XCTAssertTrue(directory.sent.isEmpty)
        XCTAssertEqual(model.record.issues[0].status, .open)
        XCTAssertNil(model.record.issues[0].sentAt)
        XCTAssertNotNil(model.sendDraft)

        directory.targets = [ReviewTarget(name: "origin", dir: NSTemporaryDirectory(), agent: "claude", status: .idle)]
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.sendWarnings, [])
    }

    /// The daemon drops a single write over its input limit yet replies ok;
    /// the Enter after it would then submit whatever the agent had typed.
    func testOversizedReviewBlocksSending() async {
        let (model, _, _) = await loadedModel()
        let body = String(repeating: "long body line\n", count: 5_000)   // 75 000 bytes each
        model.record.issues = (1...3).map {
            ReviewIssue(id: $0, anchor: anchor(), title: "t\($0)", body: body, severity: .low, status: .open, createdAt: Date())
        }
        model.beginSend()
        let size = ReviewSender.pastePayload(model.sendPreview).count
        XCTAssertGreaterThan(size, ReviewSender.maxPasteBytes)
        XCTAssertFalse(model.canSend)
        let kb = Int((Double(size) / 1024).rounded(.up))
        XCTAssertEqual(model.sendWarnings, ["The review is too large to paste (\(kb) KB) — send fewer items."])

        await model.send()
        XCTAssertTrue(directory.sent.isEmpty)
        XCTAssertTrue(model.record.issues.allSatisfy { $0.status == .open && $0.sentAt == nil })

        model.toggleSendIssue(2)
        model.toggleSendIssue(3)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.sendWarnings, [])
    }

    /// Items on lines the hunk diff does not render (made in full-file mode,
    /// or an old-side anchor on a line that is context again) are listed
    /// above the diff instead of vanishing.
    func testItemsOffTheShownLinesAreListedAboveTheDiff() async {
        let (model, _, _) = await loadedModel()
        guard case .loaded(let loaded) = model.diff else { return XCTFail("diff not loaded") }
        let rendered = DiffSplitLayout.renderedKeys(loaded, layout: model.layout)
        let shown = ReviewComment(id: UUID(), anchor: anchor(), text: "on a shown line", createdAt: Date())
        let farAway = ReviewComment(id: UUID(), anchor: anchor("a.swift", 40, "far"), text: "far", createdAt: Date())
        let restored = ReviewIssue(id: 1, anchor: anchor("a.swift", 1, "import A", side: .old), title: "r",
                                   body: "r", severity: .low, status: .open, createdAt: Date())
        var lost = ReviewIssue(id: 2, anchor: anchor("a.swift", 9, "gone"), title: "lost", body: "lost",
                               severity: .low, status: .open, createdAt: Date())
        lost.anchorState = .outdated
        let other = ReviewIssue(id: 3, anchor: anchor("b.swift", 40, "x"), title: "b", body: "b",
                                severity: .low, status: .open, createdAt: Date())
        model.record.comments = [shown, farAway]
        model.record.issues = [restored, lost, other]

        XCTAssertEqual(model.unshownItems(for: "a.swift", rendered: rendered).map(\.id),
                       ["c-\(farAway.id.uuidString)", "i-1"])
        XCTAssertEqual(model.outdatedItems(for: "a.swift").map(\.id), ["i-2"])
    }

    func testOpeningAnIssueOffTheShownLinesSwitchesToFullFile() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 5, "hunk")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "top"), (.context, 2, 2, "mid"),
                                            (.added, nil, 5, "hunk")])
        let (model, _, _) = await loadedModel(git)
        model.record.issues = [
            ReviewIssue(id: 1, anchor: anchor("a.swift", 1, "top"), title: "t", body: "t", severity: .low,
                        status: .open, createdAt: Date()),
        ]
        XCTAssertFalse(model.fullFile)
        await model.openIssue(1)
        XCTAssertTrue(model.fullFile)
        XCTAssertEqual(model.diff, .loaded(git.fullDiffs["a.swift"]!))
        XCTAssertEqual(model.scrollRequest?.rowID, "h0-l0")
    }

    func testOpeningAnIssueOnAShownLineStaysInHunks() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift")])
        git.diffs["a.swift"] = oneHunk([(.added, nil, 5, "hunk")])
        git.fullDiffs["a.swift"] = oneHunk([(.context, 1, 1, "top"), (.added, nil, 5, "hunk")])
        let (model, _, _) = await loadedModel(git)
        model.record.issues = [
            ReviewIssue(id: 1, anchor: anchor("a.swift", 5, "hunk"), title: "t", body: "t", severity: .low,
                        status: .open, createdAt: Date()),
        ]
        await model.openIssue(1)
        XCTAssertFalse(model.fullFile)
        XCTAssertEqual(model.scrollRequest?.rowID, "h0-l0")
    }

    func testNextIssueCyclesInTreeOrder() async {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("z.txt"), changed("src/a.swift")])
        let (model, _, _) = await loadedModel(git)
        model.record.issues = [
            ReviewIssue(id: 1, anchor: anchor("z.txt", 1, "z"), title: "z", body: "z", severity: .low, status: .open, createdAt: Date()),
            ReviewIssue(id: 2, anchor: anchor("src/a.swift", 9, "n"), title: "n", body: "n", severity: .low, status: .open, createdAt: Date()),
            ReviewIssue(id: 3, anchor: anchor("src/a.swift", 2, "t"), title: "t", body: "t", severity: .low, status: .open, createdAt: Date()),
        ]
        var order: [String?] = []
        for _ in 0..<4 {
            await model.nextIssue(1)
            order.append(model.selectedPath)
        }
        XCTAssertEqual(order, ["src/a.swift", "src/a.swift", "z.txt", "src/a.swift"])
    }
}
