import XCTest
@testable import covey

final class DirBrowseTests: XCTestCase {
    private var base = ""

    override func setUpWithError() throws {
        base = "\(NSTemporaryDirectory())covey-browse-\(UInt32.random(in: 0..<UInt32.max))"
        for d in ["Alpha", "beta", "Beard", ".hidden", "gamma"] {
            try FileManager.default.createDirectory(atPath: "\(base)/\(d)",
                                                    withIntermediateDirectories: true)
        }
        try "file".write(toFile: "\(base)/not-a-dir", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testSplitPath() {
        XCTAssertEqual(DirBrowse.splitPath("/a/b/c").base, "/a/b/")
        XCTAssertEqual(DirBrowse.splitPath("/a/b/c").filter, "c")
        XCTAssertEqual(DirBrowse.splitPath("/a/b/").base, "/a/b/")
        XCTAssertEqual(DirBrowse.splitPath("/a/b/").filter, "")
        XCTAssertEqual(DirBrowse.splitPath("plain").base, "")
        XCTAssertEqual(DirBrowse.splitPath("plain").filter, "plain")
    }

    func testListFiltersAndSorts() {
        XCTAssertEqual(DirBrowse.list(base: base, filter: ""),
                       ["Alpha", "Beard", "beta", "gamma"], "hidden and files excluded, ci-sorted")
        XCTAssertEqual(DirBrowse.list(base: base, filter: "be"),
                       ["Beard", "beta"], "case-insensitive prefix")
        XCTAssertEqual(DirBrowse.list(base: base, filter: ".hi"),
                       [".hidden"], "dot filter reveals hidden dirs")
        XCTAssertEqual(DirBrowse.list(base: "/definitely/not/here", filter: ""), [])
    }

    func testFieldSequence() {
        XCTAssertEqual(
            formFieldSequence(terminal: false, isRepo: false, showWorktreeToggle: false,
                              showBase: false, isClaude: true, customAgent: false),
            [.name, .dir, .terminal, .agent, .model, .effort])
        XCTAssertEqual(
            formFieldSequence(terminal: true, isRepo: true, showWorktreeToggle: true,
                              showBase: true, isClaude: false, customAgent: false),
            [.name, .dir, .terminal, .branch, .worktree, .base])
        XCTAssertEqual(
            formFieldSequence(terminal: false, isRepo: true, showWorktreeToggle: false,
                              showBase: false, isClaude: false, customAgent: true),
            [.name, .dir, .terminal, .branch, .agent, .customAgent])
    }
}
