import XCTest
@testable import covey

final class ReviewWorktreesTests: XCTestCase {
    private func candidate(_ session: String, _ dir: String, _ agent: String = "claude",
                           root: String = "/r/app") -> ReviewWorktreeCandidate {
        ReviewWorktreeCandidate(session: session, dir: dir, agent: agent, projectRoot: root)
    }

    func testOneChoicePerWorktreeInSidebarOrder() {
        let candidates = [
            candidate("agent-a", "/r/app"),
            candidate("agent-b", "/r/app/Sources", "codex"),
            candidate("agent-c", "/r/app/.worktrees/x"),
        ]
        let toplevels = ["/r/app": "/r/app", "/r/app/Sources": "/r/app",
                         "/r/app/.worktrees/x": "/r/app/.worktrees/x"]
        let choices = ReviewWorktrees.choices(candidates, toplevels: toplevels, shell: "/bin/zsh")
        XCTAssertEqual(choices.map(\.worktree), ["/r/app", "/r/app/.worktrees/x"])
        XCTAssertEqual(choices.map(\.session), ["agent-a", "agent-c"])
        XCTAssertEqual(choices.map(\.title), ["app", "x"])
        XCTAssertEqual(choices.first?.projectRoot, "/r/app")
    }

    func testShellsAndDirectoriesOutsideGitDropOut() {
        let candidates = [
            candidate("term", "/r/other", "zsh"),
            candidate("plain", "/nogit"),
            candidate("agent", "/r/other"),
        ]
        let toplevels = ["/r/other": "/r/other"]
        let choices = ReviewWorktrees.choices(candidates, toplevels: toplevels, shell: "/bin/zsh")
        XCTAssertEqual(choices.map(\.session), ["agent"], "a shell never becomes the send target")
    }

    func testNoCandidatesNoChoices() {
        XCTAssertEqual(ReviewWorktrees.choices([], toplevels: [:], shell: nil), [])
    }
}
