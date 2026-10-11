import XCTest
@testable import CoveyGit

final class RepositoryWorktreeListTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository!

    override func setUpWithError() throws {
        repo = try TestRepo()
        git = Repository(at: repo.path)
    }

    override func tearDown() {
        repo.remove()
    }

    /// git reports worktree paths through resolved symlinks (/var → /private/var).
    private func canon(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    func testListWorktreesMarksPrimaryAndLinked() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' worktree add -q -b feat '\(repo.path)/.wt-feat'")

        let entries = try git.listWorktrees()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isPrimary)                       // porcelain lists main first
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[1].branch, "feat")
        XCTAssertEqual(canon(entries[1].path), canon("\(repo.path)/.wt-feat"))
        XCTAssertFalse(entries[1].isPrimary)
    }

    func testDetachedWorktreeHasNilBranch() throws {
        try repo.commitAll("second", allowEmpty: true)
        try repo.sh("git -C '\(repo.path)' worktree add -q --detach '\(repo.path)/.wt-d'")

        let detached = try XCTUnwrap(try git.listWorktrees()
            .first { canon($0.path) == canon("\(repo.path)/.wt-d") })
        XCTAssertNil(detached.branch)
    }

    func testMergedBranchesIntoBaseExcludesCurrent() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' branch landed")
        try repo.sh("git -C '\(repo.path)' checkout -q -b feat")
        try repo.write("b.txt", "bee\n")
        try repo.commitAll("work")

        let merged = try git.mergedBranches(into: "main")
        XCTAssertEqual(Set(merged), ["landed"])                   // feat not merged; current excluded
        let intoFeat = try git.mergedBranches(into: "feat")
        XCTAssertTrue(try XCTUnwrap(intoFeat.first { $0 == "landed" }) != nil)
        XCTAssertNil(try intoFeat.first { $0 == "feat" })         // the ref itself excluded
    }

    func testDeleteBranchRollsBackWhenCheckedOut() throws {      // Review Focus 2
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' worktree add -q -b feat '\(repo.path)/.wt-feat'")
        let oid = try GitRunner.run(in: repo.path, ["rev-parse", "feat"])

        // The worktree holds feat checked out; a force delete must notice and restore.
        XCTAssertThrowsError(try git.deleteBranch("feat", force: true, protected: []))
        XCTAssertEqual(try GitRunner.run(in: repo.path, ["rev-parse", "feat"]), oid)
    }
}
