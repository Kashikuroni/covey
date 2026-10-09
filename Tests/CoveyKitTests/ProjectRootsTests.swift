import XCTest
@testable import CoveyKit

final class ProjectRootsTests: XCTestCase {
    func testWorktreeSuffixStripped() {
        XCTAssertEqual(pmProjectRoot("/a/b/.worktrees/feat/x"), "/a/b")
        XCTAssertEqual(pmProjectRoot("/a/b/.worktrees"), "/a/b")
        XCTAssertEqual(pmProjectRoot("/a/b/"), "/a/b")
        XCTAssertEqual(pmProjectRoot("/a/b"), "/a/b")
    }

    func testSessionRootPrefersWorktreeRepo() {
        var s = Session(name: "n", dir: "/r/.worktrees/x", cwd: "/r/.worktrees/x",
                        agent: "claude", created: 0)
        s.worktreeRepo = "/repo-root"
        XCTAssertEqual(pmSessionRoot(s), "/repo-root")
        s.worktreeRepo = nil
        XCTAssertEqual(pmSessionRoot(s), "/r")
    }

    func testAttributionLongestPrefixWins() {
        let roots = ["/dev/bigproj", "/dev/bigproj/repoA"]
        XCTAssertEqual(PMAttribution.projectRoot(for: "/dev/bigproj/repoA/.worktrees/x", registered: roots),
                       "/dev/bigproj/repoA")
        XCTAssertEqual(PMAttribution.projectRoot(for: "/dev/bigproj/repoB", registered: roots),
                       "/dev/bigproj")
        XCTAssertEqual(PMAttribution.projectRoot(for: "/dev/other", registered: roots), nil)
        XCTAssertEqual(PMAttribution.projectRoot(for: "/dev/bigproj2", registered: roots), nil) // не префикс-каталог
    }
}
