import XCTest
@testable import covey

final class PaneNodeTests: XCTestCase {
    // a | (b / c): вертикальный сплит a|b, b разбит горизонтально на b/c
    private var tree: PaneNode {
        .split(axis: .vertical, ratio: 0.5,
               first: .agent(session: "a"),
               second: .split(axis: .horizontal, ratio: 0.5,
                              first: .agent(session: "b"),
                              second: .agent(session: "c")))
    }

    func testLeavesTraverseDepthFirst() {
        XCTAssertEqual(tree.leaves, ["a", "b", "c"])
        XCTAssertEqual(tree.leafCount, 3)
        XCTAssertTrue(tree.contains(session: "b"))
        XCTAssertFalse(tree.contains(session: "d"))
    }

    func testSplittingNilTreeMakesTwoLeafTree() {
        let result = PaneNode.splitting(nil, focused: "a", axis: .vertical, newSession: "b")
        XCTAssertEqual(result, .split(axis: .vertical, ratio: 0.5,
                                      first: .agent(session: "a"),
                                      second: .agent(session: "b")))
    }

    func testSplittingReplacesFocusedLeafNewPaneRightOrBelow() {
        let result = PaneNode.splitting(tree, focused: "a", axis: .vertical, newSession: "d")
        XCTAssertEqual(result, .split(axis: .vertical, ratio: 0.5,
               first: .split(axis: .vertical, ratio: 0.5,
                             first: .agent(session: "a"), second: .agent(session: "d")),
               second: .split(axis: .horizontal, ratio: 0.5,
                              first: .agent(session: "b"), second: .agent(session: "c"))))
    }

    func testSplittingRefusesAtLimitAndMissingFocus() {
        var eight: PaneNode = .agent(session: "s1")
        for i in 2...8 {
            eight = PaneNode.splitting(eight, focused: "s1", axis: .vertical,
                                       newSession: "s\(i)")!
        }
        XCTAssertEqual(eight.leafCount, PaneNode.maxLeaves)
        XCTAssertNil(PaneNode.splitting(eight, focused: "s1", axis: .vertical, newSession: "s9"))
        XCTAssertNil(PaneNode.splitting(tree, focused: "zz", axis: .vertical, newSession: "d"))
    }

    func testRemovingCollapsesAndReportsSuccessor() {
        // Убираем a: ветка b/c занимает место, наследник фокуса — первый лист ветки.
        let (t, successor) = tree.removing(session: "a")
        XCTAssertEqual(t, .split(axis: .horizontal, ratio: 0.5,
                                 first: .agent(session: "b"), second: .agent(session: "c")))
        XCTAssertEqual(successor, "b")
    }

    func testRemovingLastButOneCollapsesToNil() {
        let two = PaneNode.split(axis: .vertical, ratio: 0.5,
                                 first: .agent(session: "a"), second: .agent(session: "b"))
        let (t, successor) = two.removing(session: "b")
        XCTAssertNil(t)                       // инвариант: дерево не-nil ⇔ ≥2 листа
        XCTAssertEqual(successor, "a")
        // Убрать несуществующего — no-op без изменения дерева.
        let (same, noSuccessor) = two.removing(session: "zz")
        XCTAssertEqual(same, two)
        XCTAssertNil(noSuccessor)
    }

    func testReplacingRewritesLeaf() {
        XCTAssertEqual(tree.replacing(session: "b", with: "x").leaves, ["a", "x", "c"])
    }
}
