import XCTest
@testable import CoveydCore

final class ResumeParseTests: XCTestCase {
    func testParsesBareUUID() {
        let pane = "some output\nTo continue: claude --resume 12345678-1234-1234-1234-123456789abc\n"
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 12345678-1234-1234-1234-123456789abc")
    }

    func testParsesLastHintAndIgnoresTrailingText() {
        let pane = """
        claude --resume 11111111-1111-1111-1111-111111111111
        ^Cclaude --resume 22222222-2222-2222-2222-222222222222 (to continue)
        """
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 22222222-2222-2222-2222-222222222222",
                       "scans lines from the end; text after the token ignored")
    }

    func testParsesQuotedName() {
        XCTAssertEqual(parseResumeCommand(#"claude --resume "my_session.1""#),
                       #"claude --resume "my_session.1""#)
    }

    func testRejectsShellMetacharactersInName() {
        XCTAssertNil(parseResumeCommand(#"claude --resume "a;b""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume "a$b""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume "a`b`""#))
        XCTAssertNil(parseResumeCommand(#"claude --resume """#))
    }

    func testRejectsMalformedUUID() {
        XCTAssertNil(parseResumeCommand("claude --resume 1234"))
        XCTAssertNil(parseResumeCommand("claude --resume 12345678-1234-1234-1234-12345678ZABC"))
        XCTAssertNil(parseResumeCommand("claude --resume 12345678x1234-1234-1234-123456789abc"))
    }

    func testStripsANSIBeforeMatching() {
        let pane = "\u{1b}[1mclaude --resume \u{1b}[0m12345678-1234-1234-1234-123456789abc"
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 12345678-1234-1234-1234-123456789abc")
    }

    func testParsesCRLFTerminatedPTYOutput() {
        let pane = "claude --resume 12345678-1234-1234-1234-123456789abc\r\n"
        XCTAssertEqual(parseResumeCommand(pane),
                       "claude --resume 12345678-1234-1234-1234-123456789abc",
                       "raw PTY lines end with CRLF; CR must not poison the token")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(parseResumeCommand(""))
        XCTAssertNil(parseResumeCommand("   \n   "))
    }

    func testScrollbackTailReturnsLastBytes() {
        let buf = ScrollbackBuffer(limit: 100)
        _ = buf.append(Array("0123456789".utf8))
        XCTAssertEqual(buf.tail(4), Array("6789".utf8))
        XCTAssertEqual(buf.tail(100), Array("0123456789".utf8), "cap larger than content")
    }
}
