import XCTest
import CoveyGit
@testable import covey

final class ReviewRepoServiceTests: XCTestCase {
    func testWorktreeListAndMergedRoundTripThroughRealRepository() async throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' branch landed")
        try repo.sh("git -C '\(repo.path)' worktree add -q -b feat '\(repo.path)/.wt-feat'")

        let service = ReviewGitService()
        let list = try await service.worktreeList(root: repo.path)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].isPrimary)

        let merged = try await service.mergedBranches(root: repo.path, into: "main")
        XCTAssertEqual(Set(merged), ["landed", "feat"])           // feat == main content, no own commits
    }
}
