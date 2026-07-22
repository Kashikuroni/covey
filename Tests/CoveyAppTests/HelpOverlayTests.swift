import XCTest
@testable import covey

final class HelpOverlayTests: XCTestCase {
    func testHelpDocumentsRecentSearchRestoreAndOpen() {
        let pairs = helpGroups.flatMap { $0.1 }
        XCTAssertTrue(pairs.contains { $0.0 == "/" && $0.1.contains("search") })
        XCTAssertTrue(pairs.contains { $0.0 == "h" && $0.1.contains("restore") })
        XCTAssertTrue(pairs.contains { $0.0 == "enter" && $0.1.contains("Agent") })
    }
}
