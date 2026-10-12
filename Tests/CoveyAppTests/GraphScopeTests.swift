import XCTest
import CoveyCodeGraph
@testable import covey

final class GraphScopeTests: XCTestCase {
    private func link(_ from: String, _ to: String, _ state: LinkState = .kept) -> Link {
        Link(from: from, to: to, names: [], state: state)
    }

    /// a → b → c over changed files; x (unchanged) → a; c → lib/z (unchanged);
    /// an unrelated changed pair; a self loop.
    private var links: [Link] {
        [link("a.swift", "b.swift"),
         link("b.swift", "c.swift"),
         link("x.swift", "a.swift"),
         link("c.swift", "lib/z.swift"),
         link("d/1.py", "e/2.py"),
         link("a.swift", "a.swift")]
    }

    private let files = ["a.swift", "b.swift", "c.swift", "d/1.py", "e/2.py"]

    func testFileScopeTakesDirectChangedNeighboursOnly() {
        XCTAssertEqual(GraphScope.file("a.swift").related(files: files, links: links, transitive: false),
                       ["a.swift", "b.swift"], "one hop: a uses b; lib/z is unchanged, x is not in the change")
        XCTAssertEqual(GraphScope.file("c.swift").related(files: files, links: links, transitive: false),
                       ["b.swift", "c.swift"], "the hop may point backwards")
    }

    func testFileScopeTransitiveFollowsChangedFilesOnly() {
        XCTAssertEqual(GraphScope.file("a.swift").related(files: files, links: links, transitive: true),
                       ["a.swift", "b.swift", "c.swift"], "the closure walks changed files and stops at unchanged ones")
        XCTAssertEqual(GraphScope.file("d/1.py").related(files: files, links: links, transitive: true),
                       ["d/1.py", "e/2.py"], "the unrelated pair has its own closure")
    }

    func testDirectoryScopeTakesTheFolderAndItsDirectNeighbours() {
        XCTAssertEqual(GraphScope.directory("d").related(files: files, links: links, transitive: false),
                       ["d/1.py", "e/2.py"])
    }

    func testDirectoryScopeIncludesNestedFoldersAndTransitivelyLinkedFiles() {
        let nested = ["pkg/a.swift", "pkg/sub/b.swift", "other/c.swift", "far/d.swift"]
        let chain = [link("pkg/a.swift", "pkg/sub/b.swift"), link("pkg/sub/b.swift", "other/c.swift"),
                     link("other/c.swift", "far/d.swift")]
        XCTAssertEqual(GraphScope.directory("pkg").related(files: nested, links: chain, transitive: false),
                       ["pkg/a.swift", "pkg/sub/b.swift", "other/c.swift"], "nested folders are inside")
        XCTAssertEqual(GraphScope.directory("pkg").related(files: nested, links: chain, transitive: true),
                       ["pkg/a.swift", "pkg/sub/b.swift", "other/c.swift", "far/d.swift"],
                       "transitive crosses out of the folder through linked files")
    }

    func testASeedWithNoLinksStaysAlone() {
        XCTAssertEqual(GraphScope.file("lonely.txt").related(files: ["lonely.txt"], links: links, transitive: true),
                       ["lonely.txt"])
        XCTAssertEqual(GraphScope.directory("none").related(files: files, links: links, transitive: false),
                       [], "an empty directory scopes to nothing")
    }

    func testAllScopeIsTheWholeChange() {
        XCTAssertEqual(GraphScope.all.related(files: files, links: links, transitive: false), Set(files))
    }
}
