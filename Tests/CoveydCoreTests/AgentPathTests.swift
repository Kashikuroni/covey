import XCTest
@testable import CoveydCore

final class AgentPathTests: XCTestCase {
    func testResolvesFirstWordOnPath() {
        XCTAssertEqual(AgentPath.resolve("sh"), "/bin/sh")
        XCTAssertEqual(AgentPath.resolve("sh -c true"), "/bin/sh")
        XCTAssertNil(AgentPath.resolve("definitely-not-a-binary-xyz"))
        XCTAssertNil(AgentPath.resolve(""))
    }
}
