import XCTest
@testable import CoveydCore

final class GitOpsTests: XCTestCase {
    private var repo = ""

    override func setUpWithError() throws {
        repo = "\(NSTemporaryDirectory())covey-git-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try sh("git -C '\(repo)' init -q -b main")
        try sh("git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private func sh(_ cmd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitOps.GitError("sh failed: \(cmd)") }
    }

    func testRepoRootAndBranches() throws {
        let root = GitOps.repoRoot(repo)
        XCTAssertNotNil(root)
        XCTAssertTrue(root!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent))
        XCTAssertNil(GitOps.repoRoot(NSTemporaryDirectory()))
        XCTAssertEqual(GitOps.currentBranch(repo), "main")
        XCTAssertEqual(GitOps.localBranches(repo), ["main"])
        XCTAssertTrue(GitOps.branchExists(repo, "main"))
        XCTAssertFalse(GitOps.branchExists(repo, "nope"))
    }

    func testPrepareWorktreeNewBranch() throws {
        let wt = "\(repo)/.worktrees/feat"
        try GitOps.ensureGitignore(repo, entry: ".worktrees/")
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(GitOps.branchExists(repo, "feat"))
        let ignore = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertTrue(ignore.contains(".worktrees/"))
        // idempotent gitignore
        try GitOps.ensureGitignore(repo, entry: ".worktrees/")
        let again = try String(contentsOfFile: "\(repo)/.gitignore", encoding: .utf8)
        XCTAssertEqual(ignore, again)
        // duplicate branch -> error
        XCTAssertThrowsError(try GitOps.prepareWorktree(
            repo: repo, wtPath: "\(repo)/.worktrees/feat2", newBranch: "feat", base: "main"))
        XCTAssertEqual(GitOps.worktreeForBranch(repo, "feat").map {
            URL(fileURLWithPath: $0).lastPathComponent
        }, "feat")
    }

    func testPrepareWorktreeExistingAndRemove() throws {
        try sh("git -C '\(repo)' branch other")
        let wt = "\(repo)/.worktrees/other"
        try GitOps.prepareWorktreeExisting(repo: repo, wtPath: wt, branch: "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        try GitOps.removeWorktree(repo: repo, wtPath: wt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        XCTAssertThrowsError(try GitOps.prepareWorktreeExisting(
            repo: repo, wtPath: "\(repo)/.worktrees/ghost", branch: "ghost"))
    }

    func testStaleWorktreePathIsCleared() throws {
        let wt = "\(repo)/.worktrees/feat"
        // an orphan non-empty dir at the target path, unknown to git
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "junk".write(toFile: "\(wt)/junk.txt", atomically: true, encoding: .utf8)
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        XCTAssertTrue(GitOps.branchExists(repo, "feat"), "orphan dir must not block the add")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(wt)/junk.txt"))
    }

    func testWorktreesMap() throws {
        var map = GitOps.worktrees(repo)
        XCTAssertEqual(Array(map.keys), ["main"], "main worktree is included")
        XCTAssertTrue(map["main"]!.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent))
        try sh("git -C '\(repo)' branch other")
        try GitOps.prepareWorktreeExisting(repo: repo, wtPath: "\(repo)/.worktrees/other",
                                           branch: "other")
        try sh("git -C '\(repo)' worktree add --detach '\(repo)/.worktrees/loose'")
        map = GitOps.worktrees(repo)
        XCTAssertEqual(map.keys.sorted(), ["main", "other"], "detached worktree skipped")
        XCTAssertTrue(map["other"]!.hasSuffix(".worktrees/other"))
        XCTAssertEqual(GitOps.worktrees(NSTemporaryDirectory()), [:])
    }

    func testCreateBranch() throws {
        try GitOps.createBranch(repo, "feat", base: "main")
        XCTAssertEqual(GitOps.currentBranch(repo), "feat", "created AND checked out")
        XCTAssertThrowsError(try GitOps.createBranch(repo, "feat", base: "main"),
                             "duplicate branch")
        XCTAssertThrowsError(try GitOps.createBranch(repo, "x", base: "nope"),
                             "unknown base")
    }

    func testResolveAgentPath() {
        XCTAssertEqual(GitOps.resolveAgentPath("sh"), "/bin/sh")
        XCTAssertNil(GitOps.resolveAgentPath("definitely-not-a-binary-xyz"))
        XCTAssertNil(GitOps.resolveAgentPath(""))
    }

    func testParseShortstat() {
        XCTAssertEqual(GitOps.parseShortstat(" 2 files changed, 10 insertions(+), 3 deletions(-)").added, 10)
        XCTAssertEqual(GitOps.parseShortstat(" 2 files changed, 10 insertions(+), 3 deletions(-)").removed, 3)
        XCTAssertEqual(GitOps.parseShortstat(" 1 file changed, 1 insertion(+)").added, 1)
        XCTAssertEqual(GitOps.parseShortstat(" 1 file changed, 1 insertion(+)").removed, 0)
        XCTAssertEqual(GitOps.parseShortstat("").added, 0)
    }

    func testReadGitInfo() throws {
        try "line\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add f.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m f")
        var info = GitOps.readGitInfo(repo)
        XCTAssertEqual(info?.branch, "main")
        XCTAssertEqual(info?.added, 0)
        try "line\nmore\n".write(toFile: "\(repo)/f.txt", atomically: true, encoding: .utf8)
        info = GitOps.readGitInfo(repo)
        XCTAssertEqual(info?.added, 1)
        XCTAssertNil(GitOps.readGitInfo(NSTemporaryDirectory()))
    }

    func testPromoteWorktreeMovesDirtyChanges() throws {
        let wt = "\(repo)/.worktrees/feat"
        try GitOps.prepareWorktree(repo: repo, wtPath: wt, newBranch: "feat", base: "main")
        try "wip".write(toFile: "\(wt)/wip.txt", atomically: true, encoding: .utf8)
        try GitOps.promoteWorktree(repo: repo, wtDir: wt, branch: "feat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt), "worktree removed")
        XCTAssertEqual(GitOps.currentBranch(repo), "feat", "branch checked out in root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo)/wip.txt"),
                      "uncommitted file travelled via the stash")
    }

    func testDeleteBranchMergedOnly() throws {
        try sh("git -C '\(repo)' branch merged-b")
        try GitOps.deleteBranch(repo: repo, branch: "merged-b")
        XCTAssertFalse(GitOps.branchExists(repo, "merged-b"))
        // an unmerged branch refuses -d
        try sh("git -C '\(repo)' checkout -q -b unmerged && touch '\(repo)/u.txt' && git -C '\(repo)' add u.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m u && git -C '\(repo)' checkout -q main")
        XCTAssertThrowsError(try GitOps.deleteBranch(repo: repo, branch: "unmerged"))
    }

    func testListMergedBranches() throws {
        try sh("git -C '\(repo)' branch merged-b")
        let merged = GitOps.listMergedBranches(repo)
        XCTAssertTrue(merged.contains("merged-b"))
        XCTAssertFalse(merged.contains("main"), "current branch excluded")
    }
}
