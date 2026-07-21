import XCTest
@testable import covey

final class TerminalPathFormatterTests: XCTestCase {
    func testQuotesSimpleAbsolutePath() {
        XCTAssertEqual(
            shellQuotedTerminalPath("/tmp/image.png"),
            "'/tmp/image.png'"
        )
    }

    func testQuotesSpacesMetacharactersAndUnicode() {
        XCTAssertEqual(
            shellQuotedTerminalPath("/tmp/Макет $final?.png"),
            "'/tmp/Макет $final?.png'"
        )
    }

    func testEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            shellQuotedTerminalPath("/tmp/it's ready.png"),
            "'/tmp/it'\\''s ready.png'"
        )
    }

    func testRejectsEmptyRelativeAndStructuralControlPaths() {
        XCTAssertNil(shellQuotedTerminalPath(""))
        XCTAssertNil(shellQuotedTerminalPath("relative/image.png"))
        XCTAssertNil(shellQuotedTerminalPath("/tmp/nul\0image.png"))
        XCTAssertNil(shellQuotedTerminalPath("/tmp/cr\rimage.png"))
        XCTAssertNil(shellQuotedTerminalPath("/tmp/lf\nimage.png"))
    }
}
