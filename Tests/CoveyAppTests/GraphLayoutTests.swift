import XCTest
import CoveyCodeGraph
@testable import covey

final class GraphLayoutTests: XCTestCase {
    private func link(_ from: String, _ to: String, _ state: LinkState = .kept) -> Link {
        Link(from: from, to: to, names: [], state: state)
    }

    private func layout(_ files: [String], _ links: [Link]?, selected: String? = nil,
                        users: [String] = [], used: [String] = [], expanded: Bool = false) -> GraphLayout {
        GraphLayout.make(GraphLayoutInput(files: files, links: links, selected: selected,
                                          users: users, used: used, expanded: expanded))
    }

    private let line = GraphLayout.cardSize.height + GraphLayout.lineGap
    private let caption = GraphLayout.captionHeight

    func testFoldersStackByDependencyUsersAbove() {
        let l = layout(["api/client.ts", "core/retry.ts", "ui/view.ts"],
                       [link("ui/view.ts", "api/client.ts"), link("api/client.ts", "core/retry.ts", .removed)])
        XCTAssertEqual(l.captions.map(\.text), ["ui", "api", "core"], "a removed link orders folders too")
        let y = l.rects
        XCTAssertEqual(y["ui/view.ts"]?.minY, caption)
        XCTAssertEqual(y["api/client.ts"]?.minY, caption + line + GraphLayout.groupGap + caption)
        XCTAssertLessThan(y["api/client.ts"]!.minY, y["core/retry.ts"]!.minY)
        XCTAssertEqual(Set(l.cards.map(\.rect.minX)), [0])
        XCTAssertTrue(l.cards.allSatisfy { $0.kind == .changed })
    }

    func testACycleBreaksAtTheFewestIncomingThenByPath() {
        // a has two incoming edges, b and c one each: b goes first although a sorts first.
        XCTAssertEqual(GraphLayout.order(["a", "b", "c"], edges: [("a", "b"), ("b", "c"), ("c", "a"), ("b", "a")]),
                       ["b", "c", "a"])
        XCTAssertEqual(GraphLayout.order(["y", "x"], edges: [("x", "y"), ("y", "x")]), ["x", "y"])
        XCTAssertEqual(GraphLayout.order(["b", "a"], edges: [("a", "a")]), ["a", "b"], "no loops")
        let l = layout(["a/1.rs", "b/1.rs", "c/1.rs"],
                       [link("a/1.rs", "b/1.rs"), link("b/1.rs", "c/1.rs"), link("c/1.rs", "a/1.rs"),
                        link("b/1.rs", "a/1.rs")])
        XCTAssertEqual(l.captions.map(\.text), ["b", "c", "a"])
    }

    func testInsideAFolderUsersGoLeftAndLinesWrapAfterFour() {
        let files = (1...6).map { "src/f\($0).py" }
        let links = [link("src/f6.py", "src/f1.py")] + (2...5).map { link("src/f\($0).py", "lib/x.py") }
        let l = layout(files, links)
        XCTAssertEqual(l.cards.map(\.path), ["src/f2.py", "src/f3.py", "src/f4.py", "src/f5.py",
                                             "src/f6.py", "src/f1.py"])
        let r = l.rects
        XCTAssertEqual(r["src/f5.py"]?.origin, CGPoint(x: GraphLayout.column(3), y: caption))
        XCTAssertEqual(r["src/f6.py"]?.origin, CGPoint(x: 0, y: caption + line))
        XCTAssertEqual(r["src/f1.py"]?.origin, CGPoint(x: GraphLayout.column(1), y: caption + line))
        XCTAssertEqual(l.captions.map(\.text), ["src"], "a link to an unchanged file keeps a file in its folder")
    }

    func testFilesWithoutLinksFormTheBottomBlock() {
        let lonely = ["z/a.md", "b.txt", "y/c.png", "x/d.json", "e.lock"]
        let l = layout(["src/app.py", "src/util.py"] + lonely, [link("src/app.py", "src/util.py")])
        XCTAssertEqual(l.captions.map(\.text), ["src", GraphLayout.noLinksCaption])
        let r = l.rects
        let top = caption + line + GraphLayout.groupGap + caption
        XCTAssertEqual(r["b.txt"]?.origin, CGPoint(x: 0, y: top), "the block is sorted by path")
        XCTAssertEqual(r["z/a.md"]?.origin, CGPoint(x: 0, y: top + line), "a grid of four")
        XCTAssertEqual(l.captions.last?.origin.y, caption + line + GraphLayout.groupGap)
    }

    func testWithoutLinksFoldersFollowPathOrderAndNothingIsLeftOver() {
        let l = layout(["web/b.ts", "api/z.ts", "api/a.ts", "root.ts"], nil)
        XCTAssertEqual(l.captions.map(\.text), [GraphLayout.rootCaption, "api", "web"])
        XCTAssertEqual(l.cards.map(\.path), ["root.ts", "api/a.ts", "api/z.ts", "web/b.ts"])
        XCTAssertFalse(l.captions.contains { $0.text == GraphLayout.noLinksCaption })
    }

    func testTheNeighbourRowSitsUnderTheSelectedLineAndPushesTheRestDown() {
        let files = (1...6).map { "src/f\($0).swift" }
        let links = files.map { link($0, "lib/base.swift") }
        let plain = layout(files, links)
        let l = layout(files, links, selected: "src/f2.swift", users: ["app/b.swift", "app/a.swift"],
                       used: ["lib/base.swift"])
        let r = l.rects
        let rowTop = caption + line + caption
        XCTAssertEqual(r["app/a.swift"]?.origin, CGPoint(x: 0, y: rowTop))
        XCTAssertEqual(r["app/b.swift"]?.origin, CGPoint(x: GraphLayout.column(1), y: rowTop))
        XCTAssertEqual(r["lib/base.swift"]?.origin, CGPoint(x: GraphLayout.usedX, y: rowTop))
        XCTAssertEqual(l.cards.filter { $0.kind == .user }.map(\.path), ["app/a.swift", "app/b.swift"])
        XCTAssertEqual(l.cards.first { $0.path == "lib/base.swift" }?.kind, .used)
        XCTAssertEqual(r["app/a.swift"]?.size, GraphLayout.neighbourSize)
        XCTAssertTrue(l.captions.contains(GraphCaption(text: "used by", origin: CGPoint(x: 0, y: caption + line))))
        XCTAssertTrue(l.captions.contains(GraphCaption(text: "uses",
                                                       origin: CGPoint(x: GraphLayout.usedX, y: caption + line))))
        let shift = caption + GraphLayout.neighbourSize.height + GraphLayout.lineGap
        XCTAssertEqual(r["src/f5.swift"]!.minY, plain.rects["src/f5.swift"]!.minY + shift)
        XCTAssertEqual(r["src/f1.swift"], plain.rects["src/f1.swift"], "the selected line itself stays put")
        XCTAssertEqual(l.hiddenNeighbours, 0)
    }

    func testAHubShowsEightNeighboursASideUntilExpanded() {
        let users = (10..<30).map { "users/u\($0).py" }
        let used = (10..<20).map { "deps/d\($0).py" }
        let links = users.map { link($0, "pkg/__init__.py") } + used.map { link("pkg/__init__.py", $0) }
        let collapsed = layout(["pkg/__init__.py"], links, selected: "pkg/__init__.py", users: users, used: used)
        XCTAssertEqual(collapsed.cards.filter { $0.kind == .user }.map(\.path), Array(users.prefix(8)))
        XCTAssertEqual(collapsed.cards.filter { $0.kind == .used }.map(\.path), Array(used.prefix(8)))
        XCTAssertEqual(collapsed.hiddenNeighbours, 12 + 2)
        let rows = Set(collapsed.cards.filter { $0.kind == .user }.map(\.rect.minY))
        XCTAssertEqual(rows.count, 2, "eight users wrap into two lines of four")

        let expanded = layout(["pkg/__init__.py"], links, selected: "pkg/__init__.py", users: users, used: used,
                              expanded: true)
        XCTAssertEqual(expanded.cards.count, 1 + 20 + 10)
        XCTAssertEqual(expanded.hiddenNeighbours, 0)
        XCTAssertEqual(Set(expanded.cards.filter { $0.kind == .user }.map(\.rect.minY)).count, 5)
        XCTAssertEqual(Set(expanded.cards.filter { $0.kind == .user }.map(\.rect.minX)),
                       Set((0..<4).map(GraphLayout.column)))
    }

    func testANeighbourOnBothSidesIsPlacedOnceAsAUser() {
        let l = layout(["a.py"], [link("x.py", "a.py"), link("a.py", "x.py"), link("a.py", "z.py")],
                       selected: "a.py", users: ["x.py"], used: ["x.py", "z.py"])
        XCTAssertEqual(l.cards.map(\.path), ["a.py", "x.py", "z.py"])
        XCTAssertEqual(l.cards.map(\.kind), [.changed, .user, .used])
    }

    func testTheSameInputInAnyOrderGivesTheSameFrames() {
        let files = ["b/2.ts", "a/1.ts", "b/1.ts", "c/1.ts", "a/2.ts"]
        let links = [link("a/1.ts", "b/1.ts"), link("b/2.ts", "c/1.ts"), link("c/1.ts", "a/2.ts"),
                     link("a/2.ts", "a/1.ts")]
        let first = layout(files, links, selected: "b/1.ts", users: ["u.ts", "t.ts"], used: ["v.ts"])
        let again = layout(files.reversed(), links.reversed(), selected: "b/1.ts", users: ["t.ts", "u.ts"],
                           used: ["v.ts"])
        XCTAssertEqual(first, again)
        XCTAssertEqual(first, layout(files, links, selected: "b/1.ts", users: ["u.ts", "t.ts"], used: ["v.ts"]))
    }

    @MainActor
    func testTheReviewCanvasLaysOutByFolderAndCentersTheSelectedCard() async throws {
        let git = FakeReviewGit()
        git.state = comparisonState([changed("web/b.ts"), changed("api/a.ts")])
        let (model, _) = makeReviewModel(git: git)
        model.isVisible = false   // no link build: folders in path order
        await model.start()
        XCTAssertEqual(model.graphLayout.captions.map(\.text), ["api", "web"])
        model.setCanvasViewport(CGSize(width: 1000, height: 800))
        await model.select("web/b.ts")
        model.focusCard()
        let rect = try XCTUnwrap(model.graphLayout.rects["web/b.ts"])
        XCTAssertEqual(model.canvas.toScreen(CGPoint(x: rect.midX, y: rect.midY)), CGPoint(x: 500, y: 400))
    }

    func testThreeHundredNodesLayOutUnderFiftyMilliseconds() {
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let files = (0..<260).map { "dir\($0 % 26)/file\($0).rs" }
        var links: [Link] = []
        for (i, file) in files.enumerated() {
            for _ in 0..<3 { links.append(link(file, files[next(files.count)])) }
            if i % 7 == 0 { links.append(link("outside/n\(i).rs", file)) }
        }
        let users = (0..<20).map { "callers/c\($0).rs" }
        let used = (0..<20).map { "deps/d\($0).rs" }
        let input = GraphLayoutInput(files: files, links: links, selected: files[100], users: users, used: used,
                                     expanded: true)
        var best = Double.infinity
        var result = GraphLayout()
        for _ in 0..<3 {
            let start = ContinuousClock.now
            result = GraphLayout.make(input)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        XCTAssertEqual(result.cards.count, 260 + 40, "300 nodes")
        XCTAssertLessThan(best, 0.05, "layout took \(best) s")
    }
}
