import XCTest
@testable import covey

final class IssueServiceTests: XCTestCase {
    func testIssueCreateArgs() {
        XCTAssertEqual(issueCreateArgs(title: "t", body: "b", assignMe: false, web: false),
                       ["gh", "issue", "create", "--title", "t", "--body", "b"])
        XCTAssertEqual(issueCreateArgs(title: "t", body: "b", assignMe: true, web: false),
                       ["gh", "issue", "create", "--title", "t", "--body", "b",
                        "--assignee", "@me"])
        XCTAssertEqual(issueCreateArgs(title: "t", body: "", assignMe: true, web: true),
                       ["gh", "issue", "create", "--title", "t", "--body", "",
                        "--assignee", "@me", "--web"])
    }

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
