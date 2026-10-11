import XCTest
@testable import CoveyGit

final class RepositoryMergeTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository!

    override func setUpWithError() throws {
        repo = try TestRepo()
        git = Repository(at: repo.path)
    }

    override func tearDown() {
        repo.remove()
    }

    private func sh(_ cmd: String) throws { try repo.sh(cmd) }
    private func write(_ rel: String, _ content: String) throws { try repo.write(rel, content) }

    func testFastForwardWhenBaseUnmoved() throws {
        try write("a.txt", "one\n")
        try repo.commitAll("base")
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        try write("b.txt", "bee\n")
        try sh("git -C '\(repo.path)' add b.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m work")

        let ff = try git.updateFromBase(base: "main")
        XCTAssertTrue(ff)
        let mergeCommits = try GitRunner.run(in: repo.path, ["rev-list", "--count", "--merges", "HEAD"])
        XCTAssertEqual(mergeCommits, "0")
    }

    func testAlreadyUpToDateFastForwardsTrivially() throws {
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        XCTAssertTrue(try git.updateFromBase(base: "main"))
    }

    func testDivergedCreatesMergeCommit() throws {
        try write("a.txt", "one\n")
        try repo.commitAll("base")
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        try write("b.txt", "bee\n")
        try sh("git -C '\(repo.path)' add b.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m work")
        try sh("git -C '\(repo.path)' checkout -q main")
        try write("c.txt", "cee\n")
        try sh("git -C '\(repo.path)' add c.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m onmain")
        try sh("git -C '\(repo.path)' checkout -q feat")

        let ff = try git.updateFromBase(base: "main")
        XCTAssertFalse(ff)
        let merges = try GitRunner.run(in: repo.path, ["rev-list", "--count", "--merges", "HEAD"])
        XCTAssertEqual(merges, "1")
    }

    func testUpdateFromBaseRefusesDirtyTree() throws {           // Review Focus 3
        try write("dirty.txt", "uncommitted\n")
        XCTAssertThrowsError(try git.updateFromBase(base: "main")) { error in
            XCTAssertEqual(error as? GitError, GitError("working tree has uncommitted changes"))
        }
        let mergeHead = try? GitRunner.run(
            in: repo.path, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], readOnly: true)
        XCTAssertTrue((mergeHead ?? "").isEmpty, "no merge may start on a dirty tree")
    }

    func testUpdateFromBaseAbortsOnConflict() throws {           // Review Focus 4
        try write("a.txt", "base\n")
        try repo.commitAll("base")
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        try write("a.txt", "feat side\n")
        try sh("git -C '\(repo.path)' add a.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m feat")
        try sh("git -C '\(repo.path)' checkout -q main")
        try write("a.txt", "main side\n")
        try sh("git -C '\(repo.path)' add a.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m onmain")
        try sh("git -C '\(repo.path)' checkout -q feat")
        let headBefore = try GitRunner.run(in: repo.path, ["rev-parse", "HEAD"])

        XCTAssertThrowsError(try git.updateFromBase(base: "main"))
        let mergeHead = try? GitRunner.run(in: repo.path, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], readOnly: true)
        XCTAssertTrue((mergeHead ?? "").isEmpty, "MERGE_HEAD must be gone after abort")
        let status = try GitRunner.run(in: repo.path, ["status", "--porcelain"], readOnly: true)
        XCTAssertTrue(status.isEmpty, "tree must be clean after abort, got: \(status)")
        XCTAssertEqual(try GitRunner.run(in: repo.path, ["rev-parse", "HEAD"]), headBefore)
    }

    func testUnknownBaseRefuses() throws {
        XCTAssertThrowsError(try git.updateFromBase(base: "no-such-branch")) { error in
            XCTAssertEqual(error as? GitError, GitError("unknown revision 'no-such-branch'"))
        }
    }
}

extension RepositoryMergeTests {
    func testSquashMergedDetectsLandedContent() throws {
        try write("a.txt", "base\n")
        try repo.commitAll("base")
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        try write("feature.txt", "feature work\n")
        try sh("git -C '\(repo.path)' add feature.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m feat")
        // The feature lands in main as a SQUASH commit: same content, new sha.
        try sh("git -C '\(repo.path)' checkout -q main")
        try write("feature.txt", "feature work\n")
        try sh("git -C '\(repo.path)' add feature.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m squashed")
        try sh("git -C '\(repo.path)' checkout -q feat")

        XCTAssertFalse(try git.mergedBranches(into: "main").contains("feat"), "ancestry must NOT see it")
        XCTAssertTrue(try git.squashMerged(branch: "feat", base: "main"))
    }

    func testSquashMergedFalseWhenContentDiffers() throws {
        try write("a.txt", "base\n")
        try repo.commitAll("base")
        try sh("git -C '\(repo.path)' checkout -q -b feat")
        try write("feature.txt", "feature work\n")
        try sh("git -C '\(repo.path)' add feature.txt && git -C '\(repo.path)' -c user.email=t@t -c user.name=t commit -q -m feat")

        XCTAssertFalse(try git.squashMerged(branch: "feat", base: "main"))
    }
}
