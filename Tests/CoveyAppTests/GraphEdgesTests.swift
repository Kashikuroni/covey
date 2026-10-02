import XCTest
import CoveyCodeGraph
@testable import covey

final class GraphEdgesTests: XCTestCase {
    private let card = GraphLayout.cardSize

    private func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: card)
    }

    func testATargetBelowRunsFromTheBottomEdgeToTheTopEdge() {
        let route = EdgeRoute.between(rect(0, 0), rect(308, 160))
        XCTAssertEqual(route.start, CGPoint(x: 130, y: 104))
        XCTAssertEqual(route.end, CGPoint(x: 438, y: 160))
        XCTAssertEqual(route.control1, CGPoint(x: 130, y: 104 + EdgeRoute.minBend))
        XCTAssertEqual(route.control2, CGPoint(x: 438, y: 160 - EdgeRoute.minBend))
        let head = route.arrowHead()
        XCTAssertEqual(head[0], route.end)
        XCTAssertEqual(head[1].y, 151, accuracy: 0.001, "the head points down into the top edge")
        XCTAssertEqual(head[2].y, 151, accuracy: 0.001)
        XCTAssertEqual(abs(head[1].x - head[2].x), 7, accuracy: 0.001)
    }

    func testOnTheSameLineTheArrowRunsSideToSide() {
        let right = EdgeRoute.between(rect(0, 0), rect(616, 0))
        XCTAssertEqual(right.start, CGPoint(x: 260, y: 52))
        XCTAssertEqual(right.end, CGPoint(x: 616, y: 52))
        XCTAssertLessThan(right.midpoint.y, 52, "a long reach arches over the cards between")
        XCTAssertLessThan(right.arrowHead()[1].x, 616, "the head points right")

        let left = EdgeRoute.between(rect(308, 0), rect(0, 0))
        XCTAssertEqual(left.start, CGPoint(x: 308, y: 52))
        XCTAssertEqual(left.end, CGPoint(x: 260, y: 52))
        XCTAssertGreaterThan(left.arrowHead()[1].x, 260, "the head points left")
    }

    func testALongSameLineArchLiftsAtMostOneGutter() {
        // reach 1000: the old cap (80) raised the crown over the line's top
        // edge, toward the line above.
        let long = EdgeRoute.between(rect(0, 0), rect(1260, 0))
        XCTAssertEqual(long.control1.y, 52 - GraphLayout.lineGap, accuracy: 0.001,
                       "the arch lifts at most the gap between two lines")
        XCTAssertEqual(long.control2.y, 52 - GraphLayout.lineGap, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(long.point(at: 0.5).y, 0,
                                    "the crown stays inside the line's own band")
        XCTAssertLessThan(long.point(at: 0.5).y, 52, "…and still arches over the side edges")
    }

    func testATargetAboveIsReachedAroundTheSide() {
        let up = EdgeRoute.between(rect(0, 320), rect(0, 0))
        XCTAssertEqual(up.start, CGPoint(x: 260, y: 372))
        XCTAssertEqual(up.end, CGPoint(x: 260, y: 52))
        XCTAssertEqual(up.control1, CGPoint(x: 340, y: 372))
        XCTAssertEqual(up.control2, CGPoint(x: 340, y: 52))
        XCTAssertGreaterThan(up.midpoint.x, 260, "the curve bows out beside the cards")
        XCTAssertGreaterThan(up.arrowHead()[1].x, 260, "the head points back into the right edge")

        let upLeft = EdgeRoute.between(rect(308, 320), rect(0, 0))
        XCTAssertEqual(upLeft.start, CGPoint(x: 308, y: 372))
        XCTAssertEqual(upLeft.end, CGPoint(x: 0, y: 52))
        XCTAssertEqual(upLeft.control1.x, -80)
    }

    func testTheMidpointIsHalfwayAlongTheCurve() {
        let route = EdgeRoute(start: .zero, control1: .zero, control2: CGPoint(x: 100, y: 0),
                              end: CGPoint(x: 100, y: 0))
        XCTAssertEqual(route.midpoint, CGPoint(x: 50, y: 0))
        XCTAssertEqual(route.point(at: 0), .zero)
        XCTAssertEqual(route.point(at: 1), CGPoint(x: 100, y: 0))
    }

    func testStrokesFollowTheStateAndNeighbourLinksAreDotted() {
        let changed: Set<String> = ["a", "b"]
        func stroke(_ from: String, _ to: String, _ state: LinkState) -> EdgeStroke {
            EdgeStroke.of(Link(from: from, to: to, names: [], state: state), changed: changed)
        }
        XCTAssertEqual(stroke("a", "b", .kept), .kept)
        XCTAssertEqual(stroke("a", "b", .added), .added)
        XCTAssertEqual(stroke("a", "b", .removed), .removed)
        XCTAssertEqual(stroke("x", "a", .kept), .neighbour)
        XCTAssertEqual(stroke("a", "x", .added), .neighbour)
        XCTAssertEqual(stroke("x", "a", .broken), .broken, "a broken link is news even from an unchanged file")
        XCTAssertEqual(stroke("a", "x", .removed), .removed)
        XCTAssertEqual(EdgeStroke.removed.dash, [6, 4])
        XCTAssertEqual(EdgeStroke.kept.dash, [])
        XCTAssertGreaterThan(EdgeStroke.broken.width, EdgeStroke.kept.width)
    }

    func testFocusedLabelsShowTwoNamesThenACount() {
        XCTAssertEqual(EdgeLabel.text([]), "")
        XCTAssertEqual(EdgeLabel.text(["retry"]), "retry")
        XCTAssertEqual(EdgeLabel.text(["RetryPolicy", "retry"]), "RetryPolicy, retry")
        XCTAssertEqual(EdgeLabel.text(["RetryPolicy", "retry", "a", "b"]), "RetryPolicy, retry +2")
        XCTAssertEqual(EdgeLabel.tooltip(["RetryPolicy", "retry", "a"]), "RetryPolicy, retry, a")
    }
}
