import XCTest
import CoveyCodeGraph
@testable import covey

final class LinkVisibilityTests: XCTestCase {
    // a, b, c changed; x, y unchanged (y uses a and c, a uses x).
    private let changed: Set<String> = ["a", "b", "c", "d"]
    private let ab = Link(from: "a", to: "b", names: ["B"], state: .kept)
    private let ax = Link(from: "a", to: "x", names: ["X"], state: .kept)
    private let bc = Link(from: "b", to: "c", names: ["C"], state: .added)
    private let ya = Link(from: "y", to: "a", names: ["A"], state: .kept)
    private let yc = Link(from: "y", to: "c", names: ["C"], state: .broken)
    private var links: [Link] { [ab, ax, bc, ya, yc] }

    private func resolve(show: Bool, focus: Bool, hovered: String? = nil,
                         selected: String? = nil) -> LinkVisibility {
        LinkVisibility.resolve(showLinks: show, linksOnFocus: focus, hovered: hovered, selected: selected,
                               changed: changed, links: links)
    }

    func testShowLinksDrawsEveryLinkBetweenChangedFiles() {
        for focus in [true, false] {
            let v = resolve(show: true, focus: focus)
            XCTAssertEqual(v.links, [ab, bc])
            XCTAssertNil(v.focus)
            XCTAssertFalse(v.showsNeighbours)
            XCTAssertNil(v.lit)
            XCTAssertFalse(v.dims("c"))
        }
    }

    func testShowLinksWithASelectionAddsItsNeighbourRowAndLinks() {
        let v = resolve(show: true, focus: false, selected: "a")
        XCTAssertEqual(v.links, [ab, ax, bc, ya])
        XCTAssertEqual(v.focus, "a")
        XCTAssertTrue(v.showsNeighbours)
        XCTAssertEqual(v.lit, ["a", "b", "x", "y"])
        XCTAssertTrue(v.dims("c"), "cards outside the focus fade")
        XCTAssertTrue(v.isFocused(ax))
        XCTAssertFalse(v.isFocused(bc))
        XCTAssertTrue(v.dims(bc), "links outside the focus fade")
        XCTAssertFalse(v.dims(ab))
    }

    func testFocusModeHoverShowsLinksWithChangedFilesOnly() {
        let v = resolve(show: false, focus: true, hovered: "a")
        XCTAssertEqual(v.links, [ab], "a's links to x and from y wait for a selection")
        XCTAssertEqual(v.focus, "a")
        XCTAssertFalse(v.showsNeighbours, "hovering never adds the neighbour row")
        XCTAssertEqual(v.lit, ["a", "b"])
    }

    func testFocusModeSelectionShowsAllItsLinksAndTheRow() {
        let v = resolve(show: false, focus: true, selected: "a")
        XCTAssertEqual(v.links, [ab, ax, ya])
        XCTAssertEqual(v.focus, "a")
        XCTAssertTrue(v.showsNeighbours)
    }

    func testHoverTakesTheFocusButTheSelectedRowStays() {
        let v = resolve(show: false, focus: true, hovered: "c", selected: "a")
        XCTAssertEqual(v.links, [bc], "y is unchanged: its link to c waits for c's selection")
        XCTAssertEqual(v.focus, "c")
        XCTAssertTrue(v.showsNeighbours)
        let shown = resolve(show: true, focus: true, hovered: "c", selected: "a")
        XCTAssertEqual(shown.focus, "c")
        XCTAssertEqual(shown.links, [ab, ax, bc, ya])
        XCTAssertEqual(shown.lit, ["b", "c"])
    }

    func testHoveringANeighbourShowsItsLinksToChangedFiles() {
        let v = resolve(show: false, focus: true, hovered: "y", selected: "a")
        XCTAssertEqual(v.links, [ya, yc])
        XCTAssertEqual(v.lit, ["y", "a", "c"])
    }

    func testBothOffShowCardsOnly() {
        XCTAssertEqual(resolve(show: false, focus: false, hovered: "b", selected: "a"), .none)
        XCTAssertFalse(LinkVisibility.none.dims("a"))
    }

    func testAFocusWithoutVisibleLinksDimsNothing() {
        let v = resolve(show: false, focus: true, hovered: "d")
        XCTAssertEqual(v.links, [])
        XCTAssertEqual(v.focus, "d")
        XCTAssertNil(v.lit, "sweeping the pointer over link-less cards must not flicker the canvas")
        XCTAssertFalse(v.dims("a"))
    }
}
