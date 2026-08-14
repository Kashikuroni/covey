import XCTest
import AppKit
@testable import covey

final class ThemeTests: XCTestCase {
    func testTerminalBackgroundMatchesUnifiedPanelPalette() {
        XCTAssertEqual(Theme.dark.background, NSColor(hex: 0x181C26))
        XCTAssertEqual(Theme.light.background, NSColor(hex: 0xEBEEF0))
    }

    func testAnsiHasSixteenColors() {
        XCTAssertEqual(Theme.dark.ansi.count, 16)
        XCTAssertEqual(Theme.light.ansi.count, 16)
    }

    func testAyuSpotChecks() {
        // mirage: red #F28779 at index 1, brightWhite #FFFFFF at 15
        XCTAssertEqual(Theme.dark.ansi[1], NSColor(hex: 0xF28779))
        XCTAssertEqual(Theme.dark.ansi[15], NSColor(hex: 0xFFFFFF))
        // light: green #86B300 at index 2
        XCTAssertEqual(Theme.light.ansi[2], NSColor(hex: 0x86B300))
    }
}
