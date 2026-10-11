import XCTest
@testable import covey

final class ReviewRefusalAdviceTests: XCTestCase {
    func testIndexLockGetsAdvice() {
        let message = "fatal: Unable to create '/repo/.git/index.lock': File exists"
        XCTAssertEqual(refusalAdvice(message),
                       "Another git operation is in progress — wait for the agent's git to finish, then retry")
    }

    func testNonFastForwardGetsAdvice() {
        let message = "fatal: error: failed to push some refs (hint: Updates were rejected because the tip of your current branch is behind its remote counterpart, non-fast-forward)"
        XCTAssertEqual(refusalAdvice(message),
                       "The remote moved ahead — pull with rebase in the worktree, then push again")
    }

    func testOtherMessagesPassThroughUnmapped() {
        XCTAssertNil(refusalAdvice("hook says no"))
        XCTAssertNil(refusalAdvice("nothing is staged"))
    }

    func testRefusalTextFallsBackToGitMessage() {
        struct Dummy: Error {}
        XCTAssertEqual(refusalText(Dummy()), "Dummy()")
        XCTAssertEqual(refusalText(GitLikeError(description: "hook says no")), "hook says no")
    }
}

private struct GitLikeError: Error, CustomStringConvertible {
    let description: String
}
