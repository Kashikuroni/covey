import XCTest
@testable import covey

final class ReviewPRServiceTests: XCTestCase {
    func testPrListArgsPinTheFlagLayout() {
        XCTAssertEqual(prListArgs(),
            ["gh", "pr", "list", "--state", "all", "--limit", "100",
             "--json", "number,state,headRefName,url,isDraft,title"])
    }

    func testParsePRListDecodesGhJSON() throws {
        let json = Data(#"""
        [
            {"number":7,"state":"CLOSED","headRefName":"old","url":"u7","isDraft":false,"title":"old"},
            {"number":12,"state":"OPEN","headRefName":"feat/x","url":"u12","isDraft":false,"title":"feat"}
        ]
        """#.utf8)
        let prs = parsePRList(json)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[1].number, 12)
        XCTAssertEqual(prs[1].state, "OPEN")
    }

    func testLivePRPrefersOpenThenNewestNumber() {
        let old = ReviewPR(number: 7, state: "CLOSED", headRefName: "feat/x", url: "u7",
                           isDraft: false, title: "old")
        let open = ReviewPR(number: 9, state: "OPEN", headRefName: "feat/x", url: "u9",
                            isDraft: false, title: "open")
        let openOlder = ReviewPR(number: 8, state: "OPEN", headRefName: "feat/x", url: "u8",
                                 isDraft: false, title: "open-older")
        XCTAssertEqual(livePR(forBranch: "feat/x", in: [old, openOlder, open])?.number, 9)
        XCTAssertEqual(livePR(forBranch: "feat/x", in: [old])?.number, 7)
        XCTAssertNil(livePR(forBranch: "other", in: [old, open]))
    }

    func testFetchSurvivesGhFailure() async {                    // Review Focus 5
        let service = ReviewPRService(runner: { _, _ in nil })       // nil = spawn failed
        let snapshot = await service.load(root: "/tmp/whatever")
        XCTAssertTrue(snapshot.prs.isEmpty)
        XCTAssertEqual(snapshot.error, ReviewPRService.ghNotFoundMessage)
    }

    func testCacheServesUntilRefresh() async {
        var calls = 0
        let service = ReviewPRService(runner: { _, _ in
            calls += 1
            return GhRun(status: 0,
                         stdout: Data(#"[{"number":1,"state":"OPEN","headRefName":"b","url":"u","isDraft":false,"title":"t"}]"#.utf8),
                         stderr: Data())
        })
        let first = await service.load(root: "/r")
        XCTAssertEqual(first.prs.count, 1)
        _ = await service.load(root: "/r")
        XCTAssertEqual(calls, 1, "cached within TTL")
        _ = await service.refresh(root: "/r")
        XCTAssertEqual(calls, 2, "refresh forces one call")
    }
}

extension ReviewPRServiceTests {
    func testGh127MapsToCraftedHint() async {                    // review fix I3
        let service = ReviewPRService(runner: { _, _ in
            GhRun(status: 127,
                  stdout: Data(),
                  stderr: Data("env: gh: No such file or directory".utf8))
        })
        let snapshot = await service.load(root: "/r")
        XCTAssertEqual(snapshot.error, ReviewPRService.ghNotFoundMessage)
        XCTAssertTrue(snapshot.prs.isEmpty)
    }
}
