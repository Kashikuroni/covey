import XCTest
@testable import covey

@MainActor
final class ReviewPromptSenderTests: XCTestCase {
    func testShellSessionsAreRecognised() {
        XCTAssertTrue(isShellAgent("zsh", shell: "/bin/zsh"))
        XCTAssertTrue(isShellAgent("/bin/bash", shell: nil))
        XCTAssertTrue(isShellAgent("xonsh", shell: "/opt/bin/xonsh"))
        XCTAssertFalse(isShellAgent("claude", shell: "/bin/zsh"))
        XCTAssertFalse(isShellAgent("codex", shell: "/bin/zsh"))
    }

    func testPromptListsIssuesThenComments() {
        let context = ReviewPromptContext(branch: "feat/x", comparison: "main…working tree", worktree: "/w")
        let issue = ReviewIssue(
            id: 3,
            anchor: LineAnchor(path: "Sources/A.swift", side: .new, line: 121,
                               lineText: "    let res = try await withRetry { }"),
            title: "Retry logic duplicated",
            body: "Retry logic duplicated\nApiClient.withRetry() re-implements retry().",
            severity: .high, status: .open, createdAt: Date())
        let removed = ReviewIssue(
            id: 4, anchor: LineAnchor(path: "B.swift", side: .old, line: 9, lineText: "cache.clear()"),
            title: "Why was the cache dropped?", body: "Why was the cache dropped?",
            severity: .low, status: .open, createdAt: Date())
        let comment = ReviewComment(
            id: UUID(), anchor: LineAnchor(path: "C.swift", side: .new, line: 40, lineText: "x"),
            text: "Is 10 s intentional?\nAsking for checkout.", createdAt: Date())

        XCTAssertEqual(ReviewPrompt.build(context: context, issues: [issue, removed], comments: [comment]), """
        Code review of feat/x (main…working tree) in /w.
        Address the review below; leave unrelated code alone. When done, reply with what you changed per issue number.

        ## Issues
        1. #3 · High — Retry logic duplicated
           Sources/A.swift:121
           > let res = try await withRetry { }
           ApiClient.withRetry() re-implements retry().
        2. #4 · Low — Why was the cache dropped?
           B.swift:9 (removed line)
           > cache.clear()

        ## Comments
        - C.swift:40 — Is 10 s intentional?
          Asking for checkout.

        """)
    }

    func testPromptOmitsEmptySections() {
        let context = ReviewPromptContext(branch: "b", comparison: "c", worktree: "/w")
        let text = ReviewPrompt.build(context: context, issues: [], comments: [])
        XCTAssertFalse(text.contains("## Issues"))
        XCTAssertFalse(text.contains("## Comments"))
    }

    func testSanitizeStripsEscapesAndNormalizesNewlines() {
        XCTAssertEqual(ReviewSender.sanitize("a\r\nb\rc\u{1B}[201~d"), "a\nb\nc[201~d")
    }

    func testPastePayloadIsBracketed() {
        XCTAssertEqual(ReviewSender.pastePayload("hi"),
                       [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E, 0x68, 0x69, 0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
    }

    func testDeliverPastesThenPressesEnter() async throws {
        let directory = FakeDirectory()
        try await ReviewSender.deliver("hi", to: "agent", via: directory, enterDelay: .zero)
        XCTAssertEqual(directory.sent.map(\.name), ["agent", "agent"])
        XCTAssertEqual(directory.sent[0].bytes, ReviewSender.pastePayload("hi"))
        XCTAssertEqual(directory.sent[1].bytes, [0x0D])
    }

    func testDeliverStopsAtTheFirstFailure() async {
        let directory = FakeDirectory()
        directory.failure = FakeSendError()
        do {
            try await ReviewSender.deliver("hi", to: "agent", via: directory, enterDelay: .zero)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(directory.sent.isEmpty)
        }
    }
}
