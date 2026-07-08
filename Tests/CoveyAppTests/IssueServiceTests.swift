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

    func testIssueListArgs() {
        XCTAssertEqual(issueListArgs(state: .open),
                       ["gh", "issue", "list", "--json", issueListFields,
                        "--state", "open", "--limit", "100"])
        XCTAssertEqual(issueListArgs(state: .all, limit: 50).suffix(4),
                       ["--state", "all", "--limit", "50"])
    }

    func testIssueStateCycle() {
        XCTAssertEqual(IssueState.open.next(), .closed)
        XCTAssertEqual(IssueState.closed.next(), .all)
        XCTAssertEqual(IssueState.all.next(), .open)
    }

    func testIssueEditArgsOnlyChanged() {
        XCTAssertEqual(
            issueEditArgs(number: 12, title: "t", body: nil,
                          addLabels: ["a"], removeLabels: ["b", "c"]),
            ["gh", "issue", "edit", "12", "--title", "t",
             "--add-label", "a", "--remove-label", "b", "--remove-label", "c"])
        XCTAssertEqual(issueEditArgs(number: 3, title: nil, body: "b",
                                     addLabels: [], removeLabels: []),
                       ["gh", "issue", "edit", "3", "--body", "b"])
    }

    func testCloseReopenDeleteLabelArgs() {
        XCTAssertEqual(issueCloseArgs(number: 5, reason: .notPlanned),
                       ["gh", "issue", "close", "5", "--reason", "not planned"])
        XCTAssertEqual(issueCloseArgs(number: 5, reason: .completed),
                       ["gh", "issue", "close", "5", "--reason", "completed"])
        XCTAssertEqual(issueReopenArgs(number: 5), ["gh", "issue", "reopen", "5"])
        XCTAssertEqual(issueDeleteArgs(number: 5),
                       ["gh", "issue", "delete", "5", "--yes"])
        XCTAssertEqual(labelListArgs(),
                       ["gh", "label", "list", "--json", "name,color"])
    }

    func testGhEnvironmentEnrichesBareGUIPath() {
        let env = ghEnvironment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/u"],
                                home: "/Users/u")
        let path = env["PATH"] ?? ""
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/Users/u/.local/bin"))
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"))   // system entries keep priority
    }

    func testRunGhCapturesOutputAndStatus() async {
        let ok = await runGh(args: ["sh", "-c", "echo out; echo err >&2"],
                             dir: NSTemporaryDirectory())
        XCTAssertEqual(ok?.status, 0)
        XCTAssertEqual(String(decoding: ok?.stdout ?? Data(), as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: ok?.stderr ?? Data(), as: UTF8.self), "err\n")

        let fail = await runGh(args: ["sh", "-c", "exit 3"], dir: NSTemporaryDirectory())
        XCTAssertEqual(fail?.status, 3)
    }
}
