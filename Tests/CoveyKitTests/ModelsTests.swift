import XCTest
@testable import CoveyKit

final class ModelsTests: XCTestCase {
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
    
    func testStatusRoundTrip() throws {
        for st in [Status.running, .waiting, .idle] {
            let data = try JSONEncoder().encode(st)
            XCTAssertEqual(try JSONDecoder().decode(Status.self, from: data), st)
        }
    }
}
