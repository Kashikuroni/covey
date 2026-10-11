import XCTest
@testable import CoveyGit

final class RepositoryPushTests: XCTestCase {
    private var fixture: TestClonedRepo!
    private var git: Repository!

    override func setUpWithError() throws {
        fixture = try TestClonedRepo()
        git = Repository(at: fixture.path)
    }

    override func tearDown() {
        fixture.remove()
    }

    func testUpstreamInfoReadsRemoteBranchAndCounts() throws {
        let info = try XCTUnwrap(try git.upstreamInfo())
        XCTAssertEqual(info.remote, "origin")
        XCTAssertEqual(info.branch, "dev")
        XCTAssertEqual(info.ahead, 0)
        XCTAssertEqual(info.behind, 0)
    }

    func testUpstreamInfoNilWithoutUpstream() throws {
        try fixture.sh("git -C '\(fixture.path)' switch -q -c solo")
        XCTAssertNil(try git.upstreamInfo())
    }

    func testAheadAfterLocalCommitAndBehindAfterRemoteAdvance() throws {
        try fixture.sh("git -C '\(fixture.path)' -c user.email=t@t -c user.name=t "
            + "commit -q --allow-empty -m local")
        XCTAssertEqual(try git.upstreamInfo()?.ahead, 1)

        try fixture.advanceRemoteBranch()
        try git.fetch(remote: "origin")
        let info = try XCTUnwrap(try git.upstreamInfo())
        XCTAssertEqual(info.ahead, 1)
        XCTAssertEqual(info.behind, 1)
    }

    func testPushAdvancesRemote() throws {
        try fixture.sh("git -C '\(fixture.path)' -c user.email=t@t -c user.name=t "
            + "commit -q --allow-empty -m pushme")
        try git.push(remote: "origin")
        let remoteTip = try GitRunner.run(in: fixture.origin, ["rev-parse", "dev"])
        XCTAssertEqual(remoteTip, try GitRunner.run(in: fixture.path, ["rev-parse", "dev"]))
    }

    func testPushSetUpstreamPublishesNewBranch() throws {
        try fixture.sh("git -C '\(fixture.path)' switch -q -c feature")
        try fixture.sh("git -C '\(fixture.path)' -c user.email=t@t -c user.name=t "
            + "commit -q --allow-empty -m first")
        try git.push(remote: "origin", setUpstream: true)

        let branches = try GitRunner.run(in: fixture.origin, ["branch", "--format=%(refname:short)"])
        XCTAssertTrue(branches.split(separator: "\n").contains("feature"))
        let info = try XCTUnwrap(try git.upstreamInfo())
        XCTAssertEqual(info.remote, "origin")
        XCTAssertEqual(info.branch, "feature")
    }

    func testPushRefusesWhenDetached() throws {                     // Review Focus 2 (refusal path)
        try fixture.sh("git -C '\(fixture.path)' checkout -q --detach")
        XCTAssertThrowsError(try git.push(remote: "origin")) { error in
            XCTAssertEqual(error as? GitError,
                           GitError("detached HEAD — switch to a branch before pushing"))
        }
    }
}
