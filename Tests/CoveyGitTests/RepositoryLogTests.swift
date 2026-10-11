import XCTest
@testable import CoveyGit

final class RepositoryLogTests: XCTestCase {
    func testLastCommitTimestampIsEpochSeconds() throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        let now = Int64(Date().timeIntervalSince1970)
        let stamp = try XCTUnwrap(try Repository(at: repo.path).lastCommitTimestamp())
        XCTAssertGreaterThanOrEqual(stamp, now - 60)
        XCTAssertLessThanOrEqual(stamp, now + 60)
    }

    func testAheadBehindCountsLocalRange() throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' checkout -q -b feat")
        try repo.write("b.txt", "bee\n")
        try repo.commitAll("work")

        let git = Repository(at: repo.path)                       // feat is checked out
        let pair = try git.aheadBehind(branch: "feat", base: "main")
        XCTAssertEqual(pair.ahead, 1)
        XCTAssertEqual(pair.behind, 0)
        let reverse = try git.aheadBehind(branch: "main", base: "feat")
        XCTAssertEqual(reverse.ahead, 0)
        XCTAssertEqual(reverse.behind, 1)
    }
}


extension RepositoryLogTests {
    func testBranchRecencyMapsAllBranches() throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.sh("git -C '\(repo.path)' branch feat")

        let recency = try Repository(at: repo.path).branchRecency()
        XCTAssertEqual(Set(recency.keys), ["main", "feat"])
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(recency["main"]), now - 60)
    }
}
