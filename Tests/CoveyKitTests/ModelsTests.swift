import XCTest
@testable import CoveyKit

final class ModelsTests: XCTestCase {
    func testGitInfoRoundTripsLayeredStatusAndKeepsLegacyKeys() throws {
        let info = GitInfo(
            branch: "feat/review",
            unstaged: GitDiffSummary(files: 2, added: 4, removed: 1),
            staged: GitDiffSummary(files: 1, added: 7, removed: 3),
            untracked: 5
        )

        let data = try JSONEncoder().encode(info)
        XCTAssertEqual(try JSONDecoder().decode(GitInfo.self, from: data), info)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["added"] as? Int, 4)
        XCTAssertEqual(object["removed"] as? Int, 1)
    }

    func testGitInfoDecodesLegacyCountsAsUnstaged() throws {
        let data = Data(#"{"branch":"main","added":3,"removed":2}"#.utf8)
        let info = try JSONDecoder().decode(GitInfo.self, from: data)

        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.unstaged, GitDiffSummary(files: 1, added: 3, removed: 2))
        XCTAssertEqual(info.staged, GitDiffSummary(files: 0, added: 0, removed: 0))
        XCTAssertEqual(info.untracked, 0)
    }

    func testLegacyGitInfoInitializerBuildsUnstagedSummary() {
        let info = GitInfo(branch: "main", added: 0, removed: 2)
        XCTAssertEqual(
            info.unstaged,
            GitDiffSummary(files: 1, added: 0, removed: 2)
        )
        XCTAssertEqual(info.added, 0)
        XCTAssertEqual(info.removed, 2)
    }

    func testSessionRoundTrip() throws {
        let session = Session(
            name: "s-1", dir: "/work", cwd: "/work", agent: "claude",
            created: 1_700_000_000,
            git: GitInfo(branch: "main", added: 3, removed: 1),
            worktreeRepo: "/repo"
        )
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session, back)
    }

    func testSessionProviderRoundTripsAndLegacyDefaultsToNil() throws {
        let session = Session(
            name: "glm", dir: "/work", cwd: "/work", agent: "claude",
            created: 42, providerId: "glm"
        )
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: data).providerId, "glm")

        let legacy = Data(
            #"{"name":"old","dir":"/work","cwd":"/work","agent":"claude","created":1}"#.utf8
        )
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: legacy).providerId)
    }
    
    func testStatusRoundTrip() throws {
        for st in [Status.running, .waiting, .idle] {
            let data = try JSONEncoder().encode(st)
            XCTAssertEqual(try JSONDecoder().decode(Status.self, from: data), st)
        }
    }
}
