import XCTest
@testable import CoveydCore

final class ScreenModelTests: XCTestCase {
    func testPlainTextAppearsOnScreen() {
        let screen = ScreenModel()
        screen.feed(bytes("hello\r\nworld"))
        let text = screen.visibleText()
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("world"))
    }

    // The case that broke a naive raw-scrollback port: after a redraw the
    // working marker must disappear from the visible screen.
    func testRedrawDropsStaleWorkingMarker() {
        let screen = ScreenModel()
        screen.feed(bytes("Thinking… esc to interrupt"))
        XCTAssertTrue(screen.visibleText().contains("esc to interrupt"))
        screen.feed(bytes("\u{1b}[2J\u{1b}[Hdone"))   // clear screen + home + new frame
        let text = screen.visibleText()
        XCTAssertTrue(text.contains("done"))
        XCTAssertFalse(text.contains("esc to interrupt"))
    }

    func testAlternateScreenIsTheVisibleOne() {
        let screen = ScreenModel()
        screen.feed(bytes("primary"))
        screen.feed(bytes("\u{1b}[?1049h"))            // switch to alt screen
        screen.feed(bytes("alt-content"))
        XCTAssertTrue(screen.visibleText().contains("alt-content"))
        XCTAssertFalse(screen.visibleText().contains("primary"))
    }

    func testResizeReflowsToNewWidth() {
        let screen = ScreenModel(cols: 80, rows: 24)
        screen.resize(cols: 100, rows: 30)
        let line = String(repeating: "x", count: 90)   // wraps at 80, fits at 100
        screen.feed(bytes(line))
        XCTAssertTrue(screen.visibleText().components(separatedBy: "\n").contains(line))
    }

    func testStatePreambleEmptyOnFreshModel() {
        XCTAssertEqual(ScreenModel().statePreamble(), [])
    }

    func testStatePreambleRestoresAltMouseAndPaste() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h"))
        XCTAssertEqual(screen.statePreamble(),
                       bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h"))
    }

    func testStatePreambleDropsResetModes() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?2004h"))
        screen.feed(bytes("\u{1b}[?1049l\u{1b}[?1002l"))
        XCTAssertEqual(screen.statePreamble(), bytes("\u{1b}[?2004h"))
    }

    // The preamble source must be the parsed terminal, not a byte scanner:
    // a DECSET torn across two pty chunks still counts.
    func testStatePreambleSurvivesChunkSplit() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?10"))
        screen.feed(bytes("49h"))
        XCTAssertEqual(screen.statePreamble(), bytes("\u{1b}[?1049h"))
    }

    // No 1006 in the input, 1006 in the output: the SGR assumption from the
    // design spec is deliberate.
    func testStatePreambleAnyEventMouseAndApplicationCursor() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1003h\u{1b}[?1h"))
        XCTAssertEqual(screen.statePreamble(),
                       bytes("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1h"))
    }

    func testStatePreambleRestoresKittyKeyboardFlagsWithoutPushing() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[>3u"))

        XCTAssertEqual(screen.statePreamble(), bytes("\u{1b}[=3;1u"))
    }

    func testStatePreambleSelectsAltBufferBeforeKittyKeyboardFlags() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1049h\u{1b}[>1u\u{1b}[?1002h"))

        XCTAssertEqual(
            screen.statePreamble(),
            bytes("\u{1b}[?1049h\u{1b}[=1;1u\u{1b}[?1002h\u{1b}[?1006h")
        )
    }

    func testStatePreambleDropsPoppedKittyKeyboardFlags() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[>1u\u{1b}[<u"))

        XCTAssertEqual(screen.statePreamble(), [])
    }

    // tmux capture-pane parity: without it a menu at the top of a mostly
    // blank 24-row screen falls outside parsePrompt's last-20-lines window.
    func testTrailingBlankRowsAreTrimmed() {
        let screen = ScreenModel()
        screen.feed(bytes("pick:\r\n  1. yes\r\n  2. no"))
        let lines = screen.visibleText().components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "  2. no")
    }
}
