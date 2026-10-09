import XCTest
@testable import CoveyGit

final class RepositoryIndexTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository!

    override func setUpWithError() throws {
        repo = try TestRepo()
        git = Repository(at: repo.path)
    }

    override func tearDown() {
        repo.remove()
    }

    private func byPath(_ entries: [IndexEntry]) -> [String: IndexEntry] {
        // A path can appear twice (staged deletion + untracked file on disk);
        // porcelain lists changed entries before untracked ones — keep first.
        Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testIndexStatusSplitsStagedUnstagedUntracked() throws {
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "bee\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")                       // unstaged modify
        try repo.sh("git -C '\(repo.path)' add a.txt")              // a.txt staged
        try repo.write("a.txt", "one\ntwo\nthree\n")                // …and modified again
        try repo.sh("git -C '\(repo.path)' rm -q --cached b.txt")   // staged deletion
        try repo.write("new dir/ünï code.txt", "x\n")               // untracked, after base

        let files = byPath(try git.indexStatus())
        XCTAssertTrue(try XCTUnwrap(files["a.txt"]).staged)         // Review Focus 4
        XCTAssertTrue(try XCTUnwrap(files["b.txt"]).staged)         // staged delete
        XCTAssertFalse(try XCTUnwrap(files["new dir/ünï code.txt"]).staged)
        XCTAssertTrue(try XCTUnwrap(files["new dir/ünï code.txt"]).isUntracked)
    }

    func testStagePathsAndUnstageRoundTrip() throws {
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "bee\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("b.txt", "bee\nwasp\n")

        try git.stage(paths: ["a.txt"])
        var files = byPath(try git.indexStatus())
        XCTAssertTrue(try XCTUnwrap(files["a.txt"]).staged)
        XCTAssertFalse(try XCTUnwrap(files["b.txt"]).staged)

        try git.unstage(paths: ["a.txt"])
        files = byPath(try git.indexStatus())
        XCTAssertFalse(try XCTUnwrap(files["a.txt"]).staged)
    }

    func testStageStagesDeletionsToo() throws {
        try repo.write("gone.txt", "bye\n")
        try repo.commitAll("base")
        try FileManager.default.removeItem(atPath: "\(repo.path)/gone.txt")

        try git.stage(paths: ["gone.txt"])
        XCTAssertTrue(try XCTUnwrap(byPath(try git.indexStatus())["gone.txt"]).staged)
    }

    func testStagePathsWithSpacesAndUnicode() throws {              // Review Focus 3
        try repo.commitAll("base", allowEmpty: true)
        try repo.write("new dir/ünï code.txt", "x\n")

        try git.stage(paths: ["new dir/ünï code.txt"])
        XCTAssertTrue(try XCTUnwrap(byPath(try git.indexStatus())["new dir/ünï code.txt"]).staged)
    }

    func testStageAllAndUnstageAll() throws {
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "two\n")
        try repo.write("b.txt", "new\n")

        try git.stageAll()
        XCTAssertEqual(try git.indexStatus().filter(\.staged).count, 2)
        try git.unstageAll()
        XCTAssertEqual(try git.indexStatus().filter(\.staged).count, 0)
    }
}
