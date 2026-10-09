import XCTest
@testable import CoveyGit

final class GitRunnerEnvironmentTests: XCTestCase {
    func testAdditionalEnvironmentReachesGit() throws {             // Review Focus 2 (plumbing)
        let repo = try TestRepo()
        defer { repo.remove() }
        let output = try GitRunner.run(
            in: repo.path,
            ["config", "--get", "covey.test"],
            additionalEnvironment: ["GIT_CONFIG_COUNT": "1",
                                    "GIT_CONFIG_KEY_0": "covey.test",
                                    "GIT_CONFIG_VALUE_0": "hello"])
        XCTAssertEqual(output, "hello")
    }

    func testRepositoryHelperThreadsEnvironment() throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        let output = try Repository(at: repo.path).git(
            ["config", "--get", "covey.test"],
            readOnly: true,
            additionalEnvironment: ["GIT_CONFIG_COUNT": "1",
                                    "GIT_CONFIG_KEY_0": "covey.test",
                                    "GIT_CONFIG_VALUE_0": "via-repo"])
        XCTAssertEqual(output, "via-repo")
    }
}
