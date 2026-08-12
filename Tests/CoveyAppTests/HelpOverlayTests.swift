import XCTest
@testable import covey

final class HelpOverlayTests: XCTestCase {
    func testHelpDocumentsRecentSearchRestoreAndOpen() {
        let pairs = helpGroups.flatMap { $0.1 }
        XCTAssertTrue(pairs.contains { $0.0 == "/" && $0.1.contains("search") })
        XCTAssertTrue(pairs.contains { $0.0 == "h" && $0.1.contains("restore") })
        XCTAssertTrue(pairs.contains { $0.0 == "enter" && $0.1.contains("Agent") })
    }

    func testHelpDoesNotAdvertiseRemovedNotesControls() {
        let pairs = helpGroups.flatMap { $0.1 }
        XCTAssertFalse(pairs.contains { $0.1.localizedCaseInsensitiveContains("note") })
        XCTAssertTrue(pairs.contains { $0.0 == "⌘1-5" && $0.1.contains("issues") })
    }

    func testHelpAdvertisesPaletteAndKeepsLeaderDuringCompatibilityPhase() {
        let pairs = helpGroups.flatMap(\.1)

        XCTAssertTrue(pairs.contains { $0.0 == "⌘P" && $0.1.contains("command") })
        XCTAssertTrue(helpGroups.contains { $0.0 == "leader (space)" })
    }
}
