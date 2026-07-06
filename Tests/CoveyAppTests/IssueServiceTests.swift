import XCTest
@testable import covey

final class IssueServiceTests: XCTestCase {
    func testParseIssueURLTakesLastNonEmptyLine() {
        XCTAssertEqual(parseIssueURL("https://github.com/o/r/issues/7\n"),
                       "https://github.com/o/r/issues/7")
        // gh may print progress lines first; the URL is the last one.
        XCTAssertEqual(parseIssueURL("Creating issue in o/r\n\nhttps://github.com/o/r/issues/8\n"),
                       "https://github.com/o/r/issues/8")
        XCTAssertNil(parseIssueURL(""))
        XCTAssertNil(parseIssueURL("  \n \n"))
    }
}
