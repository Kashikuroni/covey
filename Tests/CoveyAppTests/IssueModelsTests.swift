import Foundation
import XCTest
@testable import covey

final class IssueModelsTests: XCTestCase {
    // Trimmed real-shape gh output: author is an object, labels carry
    // extra keys, dates are ISO8601.
    static let issuesJSON = Data("""
    [{"number":12,"title":"Fix scroll","body":"body **md**","state":"OPEN",
      "author":{"id":"U1","is_bot":false,"login":"kashi","name":"K"},
      "labels":[{"id":"L1","name":"bug","color":"d73a4a","description":""}],
      "updatedAt":"2026-07-07T10:00:00Z",
      "url":"https://github.com/o/r/issues/12"},
     {"number":9,"title":"Тема: тёмная","body":"","state":"CLOSED",
      "author":null,"labels":[],
      "updatedAt":"2026-07-01T00:00:00Z",
      "url":"https://github.com/o/r/issues/9"}]
    """.utf8)

    func testParseIssues() throws {
        let issues = try XCTUnwrap(parseIssues(Self.issuesJSON))
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues[0].number, 12)
        XCTAssertEqual(issues[0].author, "kashi")
        XCTAssertEqual(issues[0].labels, [GhLabel(name: "bug", color: "d73a4a")])
        XCTAssertTrue(issues[0].isOpen)
        XCTAssertEqual(issues[1].author, "")      // deleted account -> ""
        XCTAssertEqual(issues[1].title, "Тема: тёмная")
        XCTAssertFalse(issues[1].isOpen)
    }

    func testParseIssuesEmptyAndBroken() {
        XCTAssertEqual(parseIssues(Data("[]".utf8)), [])
        XCTAssertNil(parseIssues(Data("not json".utf8)))
    }

    func testParseIssuesDecodesLinkedPRs() throws {
        let json = Data("""
        [{"number":5,"title":"t","body":"","state":"OPEN","author":null,
          "labels":[],"updatedAt":"2026-07-01T00:00:00Z",
          "url":"https://github.com/o/r/issues/5",
          "closedByPullRequestsReferences":[
            {"id":"PR1","number":41,"url":"https://github.com/o/r/pull/41"}]}]
        """.utf8)
        let issues = try XCTUnwrap(parseIssues(json))
        XCTAssertEqual(issues[0].linkedPRs,
                       [GhPRRef(number: 41, url: "https://github.com/o/r/pull/41")])
    }

    func testParseIssuesMissingPRKeyIsEmpty() throws {
        // The original fixture has no closedByPullRequestsReferences key.
        let issues = try XCTUnwrap(parseIssues(Self.issuesJSON))
        XCTAssertEqual(issues[0].linkedPRs, [])
    }

    func testParseLabels() throws {
        let json = Data(#"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":""}]"#.utf8)
        let labels = try XCTUnwrap(parseLabels(json))
        XCTAssertEqual(labels.map(\.name), ["bug", "ui"])
        XCTAssertNil(parseLabels(Data("{".utf8)))
    }

    func testSessionNameForIssue() {
        XCTAssertEqual(sessionNameForIssue(number: 12, title: "Fix scroll"),
                       "#12 Fix scroll")
        // ':' and '.' are forbidden by validateCreate; whitespace collapses.
        XCTAssertEqual(sessionNameForIssue(number: 7, title: "bug: v1.2  broken"),
                       "#7 bug v1 2 broken")
        let long = sessionNameForIssue(number: 1, title: String(repeating: "x", count: 100))
        XCTAssertLessThanOrEqual(long.count, 60)
        XCTAssertTrue(long.hasPrefix("#1 x"))
        // Cutting must not leave a trailing space.
        XCTAssertEqual(long, long.trimmingCharacters(in: .whitespaces))
        // Tabs and newlines collapse like spaces.
        XCTAssertEqual(sessionNameForIssue(number: 3, title: "a\tb\nc"), "#3 a b c")
        // A title that cleans to nothing falls back to the bare number.
        XCTAssertEqual(sessionNameForIssue(number: 7, title: " : . "), "#7")
    }

    func testLabelDiff() {
        let d = labelDiff(original: ["bug", "ui"], edited: ["ui", "urgent", "app"])
        XCTAssertEqual(d.add, ["app", "urgent"])
        XCTAssertEqual(d.remove, ["bug"])
        let same = labelDiff(original: ["a"], edited: ["a"])
        XCTAssertTrue(same.add.isEmpty && same.remove.isEmpty)
    }

    func testSessionNameMatchesIssue() {
        XCTAssertTrue(sessionNameMatchesIssue("#12 fix scroll", number: 12))
        XCTAssertTrue(sessionNameMatchesIssue("#12", number: 12))
        XCTAssertFalse(sessionNameMatchesIssue("#123 other", number: 12))
        XCTAssertFalse(sessionNameMatchesIssue("fix #12", number: 12))
        XCTAssertFalse(sessionNameMatchesIssue("", number: 12))
    }

    func testBranchMatchesIssue() {
        XCTAssertTrue(branchMatchesIssue("12-fix", number: 12))
        XCTAssertTrue(branchMatchesIssue("issue/12", number: 12))
        XCTAssertTrue(branchMatchesIssue("fix-12", number: 12))
        XCTAssertTrue(branchMatchesIssue("feat_12_x", number: 12))
        XCTAssertTrue(branchMatchesIssue("hotfix/#12-scroll", number: 12))
        XCTAssertFalse(branchMatchesIssue("112-fix", number: 12))
        XCTAssertFalse(branchMatchesIssue("1234", number: 12))
        XCTAssertFalse(branchMatchesIssue("fix-121", number: 12))
        XCTAssertFalse(branchMatchesIssue("#123", number: 12))
        XCTAssertFalse(branchMatchesIssue("main", number: 12))
    }

    func testRelativeAge() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-30), to: t), "now")
        XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-300), to: t), "5m")
        XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-7200), to: t), "2h")
        XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-3 * 86_400), to: t), "3d")
        XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-15 * 86_400), to: t), "2w")
    }

    func testBodyPreview() {
        XCTAssertEqual(bodyPreview("first line\nsecond"), "first line")
        XCTAssertEqual(bodyPreview("\n\n  \nreal text\nmore"), "real text")
        XCTAssertNil(bodyPreview(""))
        XCTAssertNil(bodyPreview("   \n \n"))
    }

    func testParseHexColor() {
        XCTAssertEqual(parseHexColor("d73a4a"), 0xD73A4A)
        XCTAssertEqual(parseHexColor("#FFFFFF"), 0xFFFFFF)
        XCTAssertEqual(parseHexColor("000000"), 0x000000)
        XCTAssertNil(parseHexColor(""))
        XCTAssertNil(parseHexColor("fff"))       // wrong length
        XCTAssertNil(parseHexColor("zzzzzz"))    // non-hex
    }

    func testLabelPillColorInvalid() {
        XCTAssertNil(labelPillColor(hex: "", darkTheme: false))
        XCTAssertNil(labelPillColor(hex: "xyz", darkTheme: true))
    }

    func testLabelPillColorBlendsTowardForeground() {
        let color = try! XCTUnwrap(labelPillColor(hex: "d73a4a", darkTheme: false))
        XCTAssertNotEqual(color, 0xD73A4A)
        XCTAssertEqual(color, blend(0xD73A4A, toward: 0x5C6166, labelThemeBlend))
    }

    func testLabelPillColorPaleDarkenedOnLight() {
        let color = try! XCTUnwrap(labelPillColor(hex: "ededed", darkTheme: false))
        XCTAssertLessThan(relativeLuminance(color), relativeLuminance(0xEDEDED))
    }

    func testLabelPillColorDarkLiftedOnDark() {
        let color = try! XCTUnwrap(labelPillColor(hex: "0a0a0a", darkTheme: true))
        XCTAssertGreaterThan(relativeLuminance(color), relativeLuminance(0x0A0A0A))
    }

    func testIssueCardLabelPlanCapsAtTwoAndReportsTotal() {
        let labels = [
            GhLabel(name: "bug", color: "d73a4a"),
            GhLabel(name: "critical", color: "b60205"),
            GhLabel(name: "module: web-unit", color: "1d76db"),
        ]
        let plan = issueCardLabelPlan(labels)
        XCTAssertEqual(plan.visible.map(\.name), ["bug", "critical"])
        XCTAssertEqual(plan.counter, "2/3")
    }

    func testIssueCardLabelPlanOmitsCounterWhenEverythingFits() {
        let one = issueCardLabelPlan([GhLabel(name: "bug", color: "d73a4a")])
        XCTAssertEqual(one.visible.map(\.name), ["bug"])
        XCTAssertNil(one.counter)

        let empty = issueCardLabelPlan([])
        XCTAssertTrue(empty.visible.isEmpty)
        XCTAssertNil(empty.counter)
    }

    func testIssueCardUpdatedText() {
        XCTAssertEqual(issueCardUpdatedText(age: "now"), "updated now")
        XCTAssertEqual(issueCardUpdatedText(age: "21h"), "updated 21h")
    }

    func testIssueCardHighlightRequiresSelectionAndInspectorFocus() {
        XCTAssertTrue(issueCardIsHighlighted(selected: true, inspectorFocused: true))
        XCTAssertFalse(issueCardIsHighlighted(selected: true, inspectorFocused: false))
        XCTAssertFalse(issueCardIsHighlighted(selected: false, inspectorFocused: true))
    }

    func testIssueListHeaderHidesOpenAndNamesNonDefaultFilters() {
        XCTAssertNil(issueListHeaderFilterLabel(.open))
        XCTAssertEqual(issueListHeaderFilterLabel(.closed), "CLOSED")
        XCTAssertEqual(issueListHeaderFilterLabel(.all), "ALL")
    }

    func testIssueDescriptionTrimsOrdinaryText() {
        XCTAssertEqual(issueDescription("  hello\nworld \n"), "hello\nworld")
        XCTAssertNil(issueDescription("   \n\n "))
        XCTAssertNil(issueDescription(""))
    }

    func testIssueDescriptionRemovesHTMLImagesAndKeepsText() {
        let body = """
        Before

        <img width="640" alt="capture" src="https://example.test/capture.png">

        After
        """
        XCTAssertEqual(issueDescription(body), "Before\n\nAfter")
    }

    func testIssueDescriptionRemovesMarkdownImages() {
        XCTAssertEqual(
            issueDescription("Text\n![diagram](https://example.test/diagram.png)\nMore"),
            "Text\n\nMore")
    }

    func testIssueDescriptionOmitsImageOnlyBody() {
        XCTAssertNil(issueDescription("<IMG src=\"https://example.test/a.png\" />"))
        XCTAssertNil(issueDescription("![capture](https://example.test/capture.png)"))
    }

    func testIssueWipHasDiff() {
        XCTAssertFalse(IssueWip().hasDiff)
        XCTAssertTrue(IssueWip(added: 5).hasDiff)
        XCTAssertTrue(IssueWip(removed: 3).hasDiff)
        XCTAssertFalse(IssueWip(added: 0, removed: 0).hasDiff)
    }
}
