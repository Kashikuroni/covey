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

extension ReviewRepoServiceTests {
    /// Review fix C3: promote must run from the ROOT checkout — the worktree
    /// is removed mid-operation, so a worktree receiver cannot check out.
    func testPromoteRoundTripThroughRealRepository() async throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        let wt = "\(repo.path)/.wt-feat"
        try repo.sh("git -C '\(repo.path)' worktree add -q -b feat '\(wt)'")
        try "dirty\n".write(toFile: "\(wt)/dirty.txt", atomically: true, encoding: .utf8)

        let service = ReviewGitService()
        try await service.promoteWorktree(root: repo.path, path: wt, branch: "feat")

        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        let branch = try GitRunner.run(in: repo.path, ["branch", "--show-current"])
        XCTAssertEqual(branch, "feat")
        let popped = try String(contentsOfFile: "\(repo.path)/dirty.txt", encoding: .utf8)
        XCTAssertEqual(popped, "dirty\n")
    }
}

extension ReviewRepoServiceTests {
    /// Review fix C1: the default gh runner must run inside the repository —
    /// `gh pr list` resolves the repo from its working directory.
    func testRunGhSyncRunsInTheGivenDirectory() throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        let run = runGhSync(args: ["git", "rev-parse", "--show-toplevel"], dir: repo.path)
        XCTAssertEqual(run?.status, 0)
        let canon = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        XCTAssertEqual(canon(String(decoding: run?.stdout ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)), canon(repo.path))
    }
}
