import XCTest
import CoveyGit
@testable import covey

final class ReviewModelOpsTests: XCTestCase {
    func testServiceStageAndIndexRoundTripThroughRealRepository() async throws {
        let repo = try TestRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.commitAll("base")
        try repo.write("a.txt", "two\n")

        let service = ReviewGitService()
        let before = try await service.indexStatus(worktree: repo.path)
        XCTAssertFalse(try XCTUnwrap(before.first { $0.path == "a.txt" }).staged)

        try await service.stage(worktree: repo.path, paths: ["a.txt"])
        let after = try await service.indexStatus(worktree: repo.path)
        XCTAssertTrue(try XCTUnwrap(after.first { $0.path == "a.txt" }).staged)
    }
}
