import XCTest
@testable import CoveyGit

final class RepositorySourcesTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository { Repository(at: repo.path) }

    override func setUpWithError() throws { repo = try TestRepo() }
    override func tearDown() { repo.remove() }

    private func writeBytes(_ rel: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: "\(repo.path)/\(rel)"))
    }

    func testFilesAtARevisionListTheWholeTreeSorted() throws {
        try repo.write("z.py", "z\n")
        try repo.write("pkg/sub/a.py", "a\n")
        try repo.write("b.py", "b\n")
        try repo.commitAll("files")
        try repo.write("later.py", "untracked\n")
        XCTAssertEqual(try git.files(at: "HEAD"), ["b.py", "pkg/sub/a.py", "z.py"])
        XCTAssertEqual(try git.files(at: "HEAD~1"), [])
    }

    func testWorkingTreeFilesAddUntrackedAndLeaveIgnoredOut() throws {
        try repo.write(".gitignore", "*.log\n")
        try repo.write("kept.py", "k\n")
        try repo.write("gone.py", "g\n")
        try repo.commitAll("files")
        try repo.write("new/fresh.py", "n\n")
        try repo.write("debug.log", "noise\n")
        try FileManager.default.removeItem(atPath: "\(repo.path)/gone.py")
        // The index still has gone.py: callers take deletions out themselves.
        XCTAssertEqual(try git.workingTreeFiles(), [".gitignore", "gone.py", "kept.py", "new/fresh.py"])
    }

    func testBlobReadsBytesAndSkipsMissingDirectoriesAndLargeFiles() throws {
        try repo.write("dir/a.py", "print('a')\n")
        try writeBytes("latin1.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A])
        try repo.write("big.txt", String(repeating: "x", count: 2000))
        try repo.commitAll("files")
        try repo.write("dir/a.py", "changed on disk\n")

        XCTAssertEqual(try git.blob("dir/a.py", at: "HEAD", maxBytes: 1000), Data("print('a')\n".utf8))
        XCTAssertEqual(try git.blob("latin1.txt", at: "HEAD", maxBytes: 1000),
                       Data([0x63, 0x61, 0x66, 0xE9, 0x0A]), "bytes come back as they are")
        XCTAssertNil(try git.blob("missing.py", at: "HEAD", maxBytes: 1000))
        XCTAssertNil(try git.blob("dir", at: "HEAD", maxBytes: 1000), "a directory is not a file")
        XCTAssertNil(try git.blob("big.txt", at: "HEAD", maxBytes: 1000))
        XCTAssertEqual(try git.blob("big.txt", at: "HEAD", maxBytes: 2000)?.count, 2000)
    }

    func testFilesMentioningFindsWholeWordsInTheWorkingTreeOrAtARevision() throws {
        try repo.write(".gitignore", "ignored.py\n")
        try repo.write("uses.py", "import retry\n")
        try repo.write("longer.py", "retrying = 1\n")
        try repo.write("other.py", "policy = 2\n")
        try writeBytes("blob.bin", Array("retry".utf8) + [0, 1, 2])
        try repo.commitAll("files")
        try repo.write("untracked.py", "retry()\n")
        try repo.write("ignored.py", "retry()\n")

        XCTAssertEqual(try git.filesMentioning(["retry"], at: nil), ["untracked.py", "uses.py"])
        XCTAssertEqual(try git.filesMentioning(["retry"], at: "HEAD"), ["uses.py"],
                       "the revision prefix is stripped and untracked files are not in a commit")
        XCTAssertEqual(try git.filesMentioning(["nothing_here"], at: nil), [], "exit 1 is no match")
        XCTAssertEqual(try git.filesMentioning([], at: nil), [])
    }

    func testFilesMentioningSearchesEveryBatch() throws {
        try repo.write("first.py", "alpha\n")
        try repo.write("last.py", "omega\n")
        try repo.commitAll("files")
        let filler = (0..<(Repository.grepBatch * 2)).map { "m\($0)" }
        XCTAssertEqual(try git.filesMentioning(["alpha"] + filler + ["omega"], at: "HEAD"),
                       ["first.py", "last.py"])
    }

    func testOptionShapedRevisionNeverReachesGit() {
        let calls: [() throws -> Void] = [
            { _ = try self.git.files(at: "--output=/tmp/x") },
            { _ = try self.git.blob("a.py", at: "-p", maxBytes: 10) },
            { _ = try self.git.filesMentioning(["a"], at: "") },
        ]
        for call in calls {
            XCTAssertThrowsError(try call()) { error in
                guard case .unknownRef? = (error as? GitError)?.kind else {
                    return XCTFail("expected .unknownRef, got \(error)")
                }
            }
        }
    }

    func testReadsOutsideARepositoryThrow() {
        let plain = Repository(at: NSTemporaryDirectory())
        XCTAssertThrowsError(try plain.workingTreeFiles())
        XCTAssertThrowsError(try plain.filesMentioning(["a"], at: nil))
    }
}
