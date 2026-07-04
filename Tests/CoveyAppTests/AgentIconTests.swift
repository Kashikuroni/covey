import XCTest
@testable import covey

final class AgentIconTests: XCTestCase {
    func testAgentKindClassifiesByName() {
        XCTAssertEqual(agentKind("claude"), .claude)
        XCTAssertEqual(agentKind("claude-yolo"), .claude)
        XCTAssertEqual(agentKind("/usr/local/bin/Claude"), .claude)
        XCTAssertEqual(agentKind("codex"), .codex)
        XCTAssertEqual(agentKind("my-codex --full-auto"), .codex)
        XCTAssertEqual(agentKind("aider"), .other)
        XCTAssertEqual(agentKind("sh"), .other)
        XCTAssertEqual(agentKind(""), .other)
    }

    func testClaudeIconNilForMissingApp() {
        XCTAssertNil(claudeIcon(at: "/Applications/NoSuchApp12345.app"))
    }

    func testCodexLogoFillsUnitRect() {
        let bounds = CodexLogo().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        // The blossom spans nearly the whole viewBox (simple-icons 24×24).
        XCTAssertGreaterThan(bounds.width, 20)
        XCTAssertGreaterThan(bounds.height, 20)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.minY, 0)
    }
}
