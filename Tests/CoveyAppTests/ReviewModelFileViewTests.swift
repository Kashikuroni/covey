import XCTest
import CoveyGit
import CoveyCodeGraph
@testable import covey

@MainActor
final class ReviewModelFileViewTests: XCTestCase {
    /// a.swift is changed; x.swift uses it (lines 3 and 7), a.swift uses lib/z.swift (line 2 of a.swift).
    private func started() async -> (ReviewModel, FakeReviewGraphs) {
        let userKey = LinkKey(from: "x.swift", to: "a.swift")
        let usedKey = LinkKey(from: "a.swift", to: "lib/z.swift")
        let graph = LinkGraph(
            links: [Link(from: "a.swift", to: "lib/z.swift", names: ["Z"], state: .kept),
                    Link(from: "x.swift", to: "a.swift", names: ["A"], state: .kept)],
            usages: [userKey: [UsageSite(path: "x.swift", line: 3, text: "let a = A()"),
                               UsageSite(path: "x.swift", line: 7, text: "a.run()")],
                     usedKey: [UsageSite(path: "a.swift", line: 2, text: "Z.go()")]],
            complete: true, note: nil)
        let graphs = FakeReviewGraphs(graph)
        graphs.texts = ["x.swift": "import A\r\n\r\nlet a = A()\r\n4\r\n5\r\n6\r\na.run()\r\n"]
        let git = FakeReviewGit()
        git.state = comparisonState([changed("a.swift"), changed("b.swift")])
        let (model, _) = makeReviewModel(git: git, graphs: graphs)
        model.graphInterval = .zero
        await model.start()
        _ = await eventually { model.linkGraph != nil }
        await model.select("a.swift")
        return (model, graphs)
    }

    private func card(_ model: ReviewModel, _ path: String) throws -> GraphCard {
        try XCTUnwrap(model.graphLayout.cards.first { $0.path == path })
    }

    func testNeighbourCardsListTheirUsageLines() async throws {
        let (model, _) = await started()
        let user = try card(model, "x.swift")
        XCTAssertEqual(user.kind, .user)
        XCTAssertEqual(model.neighbourSites(user).map(\.line), [3, 7], "lines in the neighbour that uses a.swift")
        let used = try card(model, "lib/z.swift")
        XCTAssertEqual(model.neighbourSites(used).map(\.path), ["a.swift"], "lines in a.swift, where it uses z")
    }

    func testAUsageLineOpensTheFileReadOnlyAtThatLine() async throws {
        let (model, _) = await started()
        let user = try card(model, "x.swift")
        let site = try XCTUnwrap(model.neighbourSites(user).last)
        await model.openUsage(site, of: try XCTUnwrap(model.neighbourKey(user)))
        let view = try XCTUnwrap(model.fileView)
        XCTAssertEqual(view.path, "x.swift")
        XCTAssertEqual(view.line, 7)
        XCTAssertEqual(view.highlighted, [3, 7])
        XCTAssertEqual(view.content, .text(["import A", "", "let a = A()", "4", "5", "6", "a.run()"]),
                       "CRLF lines are numbered like the graph numbers them")
        XCTAssertEqual(model.selectedPath, "a.swift", "the selection stays on the changed file")
    }

    func testOpenFileShowsTheNeighbourItself() async throws {
        let (model, graphs) = await started()
        await model.openNeighbour(try card(model, "x.swift"))
        XCTAssertEqual(model.fileView?.line, 3, "a user opens at its first usage")
        XCTAssertEqual(model.fileView?.highlighted, [3, 7])

        graphs.texts["lib/z.swift"] = "struct Z {}\n"
        await model.openNeighbour(try card(model, "lib/z.swift"))
        XCTAssertEqual(model.fileView?.path, "lib/z.swift")
        XCTAssertNil(model.fileView?.line, "a used file has no usage lines of its own: the top")
        XCTAssertEqual(model.fileView?.highlighted, [])
        XCTAssertEqual(model.fileView?.content, .text(["struct Z {}"]))
    }

    func testAFileThatCannotBeReadSaysSo() async throws {
        let (model, _) = await started()
        await model.openFile("gone.swift", line: 1, highlighted: [1])
        XCTAssertEqual(model.fileView?.content, .unavailable)
    }

    func testEscapeOrAChangedFileBringsTheDiffBack() async throws {
        let (model, _) = await started()
        await model.openNeighbour(try card(model, "x.swift"))
        await model.escape()
        XCTAssertNil(model.fileView)
        XCTAssertTrue(model.diffOpen, "Esc closes the read-only view first, the diff stays")
        await model.openNeighbour(try card(model, "x.swift"))
        await model.select("b.swift")
        XCTAssertNil(model.fileView)
        XCTAssertEqual(model.selectedPath, "b.swift")
    }

    func testFileLinesSplitOnlyAtLineFeeds() {
        XCTAssertEqual(ReviewModel.fileLines("a\r\nb\n\nc"), ["a", "b", "", "c"])
        XCTAssertEqual(ReviewModel.fileLines("a\n"), ["a"])
        XCTAssertEqual(ReviewModel.fileLines(""), [""])
        XCTAssertEqual(ReviewModel.fileLines("x\ry"), ["x\ry"], "a lone CR is not a line break for the graph")
    }
}
