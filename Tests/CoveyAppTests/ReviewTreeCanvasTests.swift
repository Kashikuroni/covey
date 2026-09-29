import XCTest
import CoveyGit
@testable import covey

final class ReviewTreeCanvasTests: XCTestCase {
    private func file(_ path: String, _ status: FileStatus = .modified) -> ChangedFile {
        ChangedFile(path: path, status: status, added: 1, removed: 0)
    }

    func testTreeOrderPutsDirectoriesFirstAtEveryLevel() {
        let sorted = ReviewFileTree.sorted(["b.txt", "a/z.txt", "a/b/c.txt", "A.md"].map { file($0) })
        XCTAssertEqual(sorted.map(\.path), ["a/b/c.txt", "a/z.txt", "A.md", "b.txt"])
    }

    func testRowsEmitEachDirectoryOnceWithDepth() {
        let rows = ReviewFileTree.rows(["src/api/client.ts", "src/api/retry.ts", "src/main.ts"].map { file($0) },
                                       collapsed: [])
        XCTAssertEqual(rows.map(\.id), ["d:src", "d:src/api", "f:src/api/client.ts", "f:src/api/retry.ts", "f:src/main.ts"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 1])
        XCTAssertEqual(rows.map(\.name), ["src", "api", "client.ts", "retry.ts", "main.ts"])
    }

    func testCollapsedDirectoryHidesEverythingBelowIt() {
        let rows = ReviewFileTree.rows(["src/api/client.ts", "src/main.ts", "z.txt"].map { file($0) },
                                       collapsed: ["src"])
        XCTAssertEqual(rows.map(\.id), ["d:src", "f:z.txt"])
        XCTAssertEqual(rows.first?.kind, .directory(path: "src", expanded: false))
    }

    func testFilterCombinesQueryStatusesAndFlags() {
        var filter = FileFilter()
        let reviewed = FileReview(state: .reviewed)
        let changed = FileReview(state: .reviewing, changedSinceReviewed: true)
        XCTAssertTrue(ReviewFileTree.matches(file("src/App.swift"), filter: filter, review: FileReview(), hasOpenIssues: false))
        filter.query = "app"
        XCTAssertTrue(ReviewFileTree.matches(file("src/App.swift"), filter: filter, review: FileReview(), hasOpenIssues: false))
        XCTAssertFalse(ReviewFileTree.matches(file("src/Other.swift"), filter: filter, review: FileReview(), hasOpenIssues: false))
        filter = FileFilter()
        filter.statuses = [.added]
        XCTAssertFalse(ReviewFileTree.matches(file("a", .modified), filter: filter, review: FileReview(), hasOpenIssues: false))
        filter = FileFilter()
        filter.unreviewedOnly = true
        XCTAssertFalse(ReviewFileTree.matches(file("a"), filter: filter, review: reviewed, hasOpenIssues: false))
        filter = FileFilter()
        filter.withIssuesOnly = true
        XCTAssertTrue(ReviewFileTree.matches(file("a"), filter: filter, review: reviewed, hasOpenIssues: true))
        XCTAssertFalse(ReviewFileTree.matches(file("a"), filter: filter, review: reviewed, hasOpenIssues: false))
        filter = FileFilter()
        filter.changedOnly = true
        XCTAssertTrue(ReviewFileTree.matches(file("a"), filter: filter, review: changed, hasOpenIssues: false))
        XCTAssertFalse(ReviewFileTree.matches(file("a"), filter: filter, review: reviewed, hasOpenIssues: false))
    }

    func testGlyphPrefersOpenIssues() {
        XCTAssertEqual(ReviewGlyph.of(FileReview(), hasOpenIssues: false), .unread)
        XCTAssertEqual(ReviewGlyph.of(FileReview(state: .reviewing), hasOpenIssues: false), .reviewing)
        XCTAssertEqual(ReviewGlyph.of(FileReview(state: .reviewed), hasOpenIssues: false), .reviewed)
        XCTAssertEqual(ReviewGlyph.of(FileReview(state: .reviewed), hasOpenIssues: true), .issues)
        XCTAssertEqual([ReviewGlyph.unread, .reviewing, .reviewed, .issues].map(\.symbol), ["○", "◐", "✓", "!"])
    }

    func testFramesPutOneColumnPerDirectory() {
        let frames = CanvasLayout.frames(for: ["a/2.swift", "b/1.swift", "root.txt", "a/1.swift"].map { file($0) })
        let byPath = Dictionary(uniqueKeysWithValues: frames.map { ($0.path, $0.rect) })
        let step = CanvasLayout.cardSize.width + CanvasLayout.columnGap
        XCTAssertEqual(byPath["root.txt"]?.minX, 0)
        XCTAssertEqual(byPath["a/1.swift"]?.minX, step)
        XCTAssertEqual(byPath["a/2.swift"]?.minY, CanvasLayout.cardSize.height + CanvasLayout.rowGap)
        XCTAssertEqual(byPath["b/1.swift"]?.minX, 2 * step)
        XCTAssertEqual(CanvasLayout.bounds(frames)?.minX, 0)
        XCTAssertNil(CanvasLayout.bounds([]))
    }

    func testFitCentersHorizontallyAndClampsZoom() {
        let fit = CanvasTransform.fit(CGRect(x: 0, y: 0, width: 1000, height: 500),
                                      in: CGSize(width: 600, height: 700))
        XCTAssertEqual(fit.zoom, 0.52, accuracy: 0.0001)
        XCTAssertEqual(fit.pan.width, 40, accuracy: 0.0001)
        XCTAssertEqual(fit.pan.height, 150, accuracy: 0.0001)
        let small = CanvasTransform.fit(CGRect(x: 0, y: 0, width: 100, height: 100),
                                        in: CGSize(width: 2000, height: 2000))
        XCTAssertEqual(small.zoom, 1, "never zooms past 100% to fit")
    }

    func testFitOfNothingIsIdentity() {
        XCTAssertEqual(CanvasTransform.fit(nil, in: CGSize(width: 800, height: 600)), CanvasTransform())
        XCTAssertEqual(CanvasTransform.fit(CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero), CanvasTransform())
    }

    func testZoomAroundAPointKeepsItFixed() {
        let t = CanvasTransform(zoom: 1, pan: CGSize(width: 10, height: 20))
        let anchor = CGPoint(x: 110, y: 120)
        let world = t.toWorld(anchor)
        let zoomed = t.zoomed(by: 2, around: anchor)
        XCTAssertEqual(zoomed.zoom, 2)
        XCTAssertEqual(zoomed.toScreen(world).x, anchor.x, accuracy: 0.0001)
        XCTAssertEqual(zoomed.toScreen(world).y, anchor.y, accuracy: 0.0001)
        XCTAssertEqual(t.zoomed(by: 100, around: anchor).zoom, CanvasTransform.zoomRange.upperBound)
    }

    func testCenteredPutsRectMidpointInViewportCenter() {
        let t = CanvasTransform(zoom: 0.5, pan: .zero)
            .centered(on: CGRect(x: 100, y: 100, width: 200, height: 100), in: CGSize(width: 800, height: 600))
        XCTAssertEqual(t.toScreen(CGPoint(x: 200, y: 150)), CGPoint(x: 400, y: 300))
    }
}
