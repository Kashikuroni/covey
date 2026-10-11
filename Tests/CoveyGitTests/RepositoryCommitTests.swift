import XCTest
@testable import CoveyGit

final class RepositoryCommitTests: XCTestCase {
    private var repo: TestRepo!
    private var git: Repository!

    override func setUpWithError() throws {
        repo = try TestRepo()
        git = Repository(at: repo.path)
    }

    override func tearDown() {
        repo.remove()
    }

    private func lastMessage() throws -> String {
        try GitRunner.run(in: repo.path, ["log", "-1", "--format=%B"])
    }

    func testCommitReturnsNewHeadAndCarriesBody() throws {
        try repo.write("a.txt", "one\n")
        try git.stage(paths: ["a.txt"])

        let oid = try git.commit(summary: "add a", body: "longer\nexplanation\n")
        XCTAssertEqual(oid, try GitRunner.run(in: repo.path, ["rev-parse", "HEAD"]))
        // GitRunner trims stdout, so the trailing newline is gone here.
        XCTAssertEqual(try lastMessage(), "add a\n\nlonger\nexplanation")
    }

    func testCommitRefusesWithNothingStaged() throws {
        XCTAssertFalse(try git.hasStagedChanges())
        XCTAssertThrowsError(try git.commit(summary: "empty")) { error in
            XCTAssertEqual(error as? GitError, GitError("nothing is staged — stage changes before committing"))
        }
    }

    func testCommitRefusesEmptySummary() throws {
        try repo.write("a.txt", "one\n")
        try git.stage(paths: ["a.txt"])
        XCTAssertThrowsError(try git.commit(summary: "   \n")) { error in
            XCTAssertEqual(error as? GitError, GitError("commit summary is empty"))
        }
    }

    func testAmendSkipsTheStagedCheck() throws {
        try git.commit(summary: "amended", body: "", amend: true)   // nothing staged, still legal
        XCTAssertEqual(try lastMessage(), "amended")
    }

    func testHookRejectionSurfacesHookOutput() throws {             // Review Focus 5
        try repo.write(".git/hooks/pre-commit", "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
        try repo.sh("chmod +x '\(repo.path)/.git/hooks/pre-commit'")
        try repo.write("a.txt", "one\n")
        try git.stage(paths: ["a.txt"])

        XCTAssertThrowsError(try git.commit(summary: "blocked")) { error in
            XCTAssertTrue(String(describing: error).contains("hook says no"),
                          "hook output must reach the error verbatim, got: \(error)")
        }
    }
}
