import XCTest
import CoveyGit
import CoveyKit
import CoveyCodeGraph
@testable import covey

@MainActor
final class ReviewModelGraphTests: XCTestCase {
    private func link(_ from: String, _ to: String, _ state: LinkState = .kept) -> Link {
        Link(from: from, to: to, names: ["N"], state: state)
    }

    private func graph(_ links: [Link], complete: Bool = true, note: String? = nil) -> LinkGraph {
        LinkGraph(links: links, usages: [:], complete: complete, note: note)
    }

    /// a.swift uses b.swift; x.swift (unchanged) uses a.swift; a.swift uses lib/z.swift.
    private var linked: LinkGraph {
        graph([link("a.swift", "b.swift"), link("a.swift", "lib/z.swift"), link("x.swift", "a.swift")])
    }

    private func started(_ graphs: FakeReviewGraphs, visible: Bool = true,
                         files: [ChangedFile] = [changed("a.swift"), changed("b.swift")])
        async -> (ReviewModel, FakeReviewGit) {
        let git = FakeReviewGit()
        git.state = comparisonState(files)
        let (model, _) = makeReviewModel(git: git, graphs: graphs)
        model.graphInterval = .zero
        model.isVisible = visible
        await model.start()
        return (model, git)
    }

    func testTheFirstLoadBuildsLinksAndCountsThem() async {
        let graphs = FakeReviewGraphs(linked)
        let (model, _) = await started(graphs)
        let landed = await eventually { model.linkGraph != nil && !model.graphUpdating }
        XCTAssertTrue(landed)
        XCTAssertEqual(graphs.calls.map(\.fingerprint), ["fp-1"])
        XCTAssertEqual(model.linkSummary.outgoing["a.swift"], 2)
        XCTAssertEqual(model.linkSummary.incoming["a.swift"], 1)
        XCTAssertEqual(model.linkSummary.incoming["b.swift"], 1)
        XCTAssertNil(model.graphNotice)
        XCTAssertEqual(model.graphLinks, linked.links)
    }

    func testStillUsedByCountsBrokenLinksWhateverTheSettings() async {
        let renamed = ChangedFile(path: "b.swift", oldPath: "old/b.swift", status: .renamed, added: 0, removed: 0)
        let broken = graph([link("a.swift", "b.swift"), link("x.swift", "b.swift", .broken),
                            link("y.swift", "b.swift", .broken)])
        let (model, _) = await started(FakeReviewGraphs(broken), files: [changed("a.swift"), renamed])
        _ = await eventually { model.linkGraph != nil }
        model.linkSettings.showLinks = false
        model.linkSettings.linksOnFocus = false
        XCTAssertEqual(model.linkVisibility, .none, "no links drawn…")
        XCTAssertEqual(model.linkSummary.brokenUsers["b.swift"], 2, "…but the card still says who uses it")
        XCTAssertEqual(model.linkSummary.incoming["b.swift"], 3)
        XCTAssertNil(model.linkSummary.brokenUsers["a.swift"])
    }

    func testAnUnchangedFingerprintDoesNotRebuild() async {
        let graphs = FakeReviewGraphs(linked)
        let (model, _) = await started(graphs)
        _ = await eventually { model.linkGraph != nil }
        await model.checkFreshness()
        model.isVisible = false
        model.isVisible = true
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(graphs.calls.count, 1, "the same fingerprint keeps its graph")
    }

    func testANewFingerprintRebuildsAtMostOncePerInterval() async {
        let first = linked
        let graphs = FakeReviewGraphs(first)
        let (model, git) = await started(graphs)
        model.graphInterval = .milliseconds(400)
        _ = await eventually { model.linkGraph != nil }
        let second = graph([link("b.swift", "a.swift")])
        graphs.graph = second
        git.state = comparisonState([changed("a.swift"), changed("b.swift")], fingerprint: "fp-2")
        await model.checkFreshness()
        XCTAssertTrue(model.graphUpdating, "Updating links… while the next build waits its turn")
        XCTAssertEqual(model.linkGraph, first, "the old graph stays on screen meanwhile")
        git.state = comparisonState([changed("a.swift"), changed("b.swift")], fingerprint: "fp-3")
        await model.checkFreshness()
        let rebuilt = await eventually { model.linkGraph == second && !model.graphUpdating }
        XCTAssertTrue(rebuilt)
        let calls = graphs.calls
        XCTAssertEqual(calls.map(\.fingerprint), ["fp-1", "fp-3"], "fp-2 was superseded before it started")
        XCTAssertGreaterThanOrEqual(calls[1].at - calls[0].at, .milliseconds(400))
    }

    func testAResultForALeftComparisonIsDropped() async {
        let old = linked
        let graphs = FakeReviewGraphs(old)
        let gate = graphs.holdNextBuild()
        let (model, git) = await started(graphs)
        await gate.waitUntilArrived()
        let fresh = graph([link("c.swift", "d.swift")])
        graphs.graph = fresh
        git.statesByBase["develop"] = comparisonState([changed("c.swift"), changed("d.swift")], fingerprint: "fp-d")
        await model.open(GitComparison(base: "develop"))
        let landed = await eventually { model.linkGraph == fresh }
        XCTAssertTrue(landed)
        gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.linkGraph, fresh, "the left comparison's links never land")
        XCTAssertFalse(model.graphUpdating)
    }

    func testLeavingReviewDropsTheBuildAndComingBackRebuilds() async {
        let graphs = FakeReviewGraphs(linked)
        let gate = graphs.holdNextBuild()
        let (model, _) = await started(graphs)
        await gate.waitUntilArrived()
        model.isVisible = false
        XCTAssertFalse(model.graphUpdating)
        gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.linkGraph, "a result for the hidden mode is dropped")
        model.isVisible = true
        let landed = await eventually { model.linkGraph == self.linked }
        XCTAssertTrue(landed)
        XCTAssertEqual(graphs.calls.count, 2)
    }

    func testAHiddenReviewBuildsNothingUntilShown() async {
        let graphs = FakeReviewGraphs(linked)
        let (model, _) = await started(graphs, visible: false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(graphs.calls.count, 0)
        model.isVisible = true
        let landed = await eventually { model.linkGraph != nil }
        XCTAssertTrue(landed)
    }

    func testAFailedBuildIsUnavailableAndRetryRebuilds() async {
        let graphs = FakeReviewGraphs(.unavailable("git grep failed"))
        let (model, _) = await started(graphs)
        _ = await eventually { model.linkGraph != nil }
        XCTAssertEqual(model.graphNotice, .unavailable("links unavailable: git grep failed"))
        XCTAssertEqual(model.graphNotice?.text, "Links unavailable: git grep failed")
        XCTAssertNil(model.graphLinks, "no links: the layout keeps plain folder groups")
        XCTAssertFalse(model.graphLayout.captions.contains { $0.text == GraphLayout.noLinksCaption })
        graphs.graph = linked
        model.retryGraph()
        let recovered = await eventually { model.linkGraph == self.linked }
        XCTAssertTrue(recovered)
        XCTAssertEqual(graphs.calls.count, 2, "Retry rebuilds the same fingerprint")
        XCTAssertNil(model.graphNotice)
    }

    func testAnIncompleteGraphKeepsItsLinksAndSaysSo() async {
        let partial = graph([link("a.swift", "b.swift")], complete: false, note: LinkGraph.incompleteNote)
        let (model, _) = await started(FakeReviewGraphs(partial))
        _ = await eventually { model.linkGraph != nil }
        XCTAssertEqual(model.graphNotice, .incomplete)
        XCTAssertEqual(model.graphNotice?.text, "Links incomplete")
        XCTAssertEqual(model.graphLinks, partial.links)
    }

    func testShowingOrHoveringLinksNeverMovesACard() async {
        let (model, _) = await started(FakeReviewGraphs(linked))
        _ = await eventually { model.linkGraph != nil }
        let before = model.graphLayout
        model.linkSettings.toggleShowLinks()
        XCTAssertEqual(model.graphLayout, before)
        model.hover("b.swift", inside: true)
        XCTAssertEqual(model.graphLayout, before, "hovering never inserts the neighbour row")
        await model.select("a.swift")
        let selected = model.graphLayout
        model.linkSettings.toggleShowLinks()
        XCTAssertEqual(model.graphLayout, selected, "Links on focus keeps the row when Show links goes off")
        model.hover("b.swift", inside: false)
        XCTAssertNil(model.hoveredPath)
    }

    func testSelectingAFileAddsItsNeighbourRowAndCentersIt() async throws {
        let (model, _) = await started(FakeReviewGraphs(linked))
        _ = await eventually { model.linkGraph != nil }
        model.setCanvasViewport(CGSize(width: 1200, height: 800))
        await model.select("a.swift")
        let layout = model.graphLayout
        XCTAssertEqual(layout.cards.filter { $0.kind == .user }.map(\.path), ["x.swift"])
        XCTAssertEqual(layout.cards.filter { $0.kind == .used }.map(\.path), ["lib/z.swift"])
        let rect = try XCTUnwrap(layout.rects["a.swift"])
        XCTAssertEqual(model.canvas.toScreen(CGPoint(x: rect.midX, y: rect.midY)), CGPoint(x: 600, y: 400))

        model.hover("x.swift", inside: true)
        await model.select("b.swift")
        XCTAssertNil(model.hoveredPath, "the hovered neighbour left with a's row")

        model.linkSettings.linksOnFocus = false
        XCTAssertFalse(model.graphLayout.cards.contains { $0.kind != .changed }, "both settings off: cards only")
    }

    func testMoreNeighboursExpandUntilTheSelectionMoves() async {
        let users = (0..<11).map { "callers/c\($0).swift" }
        let hub = graph(users.map { link($0, "a.swift") } + [link("a.swift", "b.swift")])
        let (model, _) = await started(FakeReviewGraphs(hub))
        _ = await eventually { model.linkGraph != nil }
        await model.select("a.swift")
        XCTAssertEqual(model.graphLayout.hiddenNeighbours, 3)
        model.expandNeighbours()
        XCTAssertEqual(model.graphLayout.hiddenNeighbours, 0)
        XCTAssertEqual(model.graphLayout.cards.filter { $0.kind == .user }.count, 11)
        await model.select("b.swift")
        XCTAssertFalse(model.neighboursExpanded)
    }

    func testAReplacedReviewDropsItsBuild() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (app, _) = try makeModel(daemon)
        await app.start()
        let reviews = ReviewFixture(app)
        let gate = reviews.graphs.holdNextBuild()
        await app.openReview(ReviewOpening(worktree: "/tmp", projectRoot: "/tmp", originSession: nil))
        let first = try XCTUnwrap(app.review)
        await gate.waitUntilArrived()
        XCTAssertTrue(first.graphUpdating)
        await app.openReview(ReviewOpening(worktree: "/usr", projectRoot: "/usr", originSession: nil))
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(first.graphUpdating, "the old worktree's build is abandoned")
        gate.release()
        let second = try XCTUnwrap(app.review)
        XCTAssertNotIdentical(first, second)
        let landed = await eventually { second.linkGraph != nil }
        XCTAssertTrue(landed)
    }
}
