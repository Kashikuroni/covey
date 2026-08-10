import XCTest
@testable import covey

/// The workspace cards are inset from the window edges and separated by
/// gutters, so every width — and the drag that sets it — has to come off the
/// same inner width. These pin that arithmetic down.
final class PanelLayoutTests: XCTestCase {
    private func make(total: CGFloat, sessions: Bool = true, inspector: Bool = true,
                      splitPct: Int = 38, sbWidth: Int = 360) -> PanelLayout {
        PanelLayout.make(total: total, showSessions: sessions, showInspector: inspector,
                         splitPct: splitPct, sbWidth: sbWidth)
    }

    func testInnerWidthDropsEdgesAndGutters() {
        let layout = make(total: 1000)
        XCTAssertEqual(layout.inner, 1000 - Tokens.edge * 2 - Tokens.gutter * 2)
    }

    func testHidingAZoneDropsItsGutter() {
        let layout = make(total: 1000, inspector: false)
        XCTAssertEqual(layout.inner, 1000 - Tokens.edge * 2 - Tokens.gutter)
        XCTAssertEqual(layout.inspector, 0)
    }

    func testZonesFillTheInnerWidthExactly() {
        let layout = make(total: 1400)
        XCTAssertEqual(layout.sessions + layout.terminal + layout.inspector,
                       layout.inner, accuracy: 0.001)
    }

    func testSessionListStopsAtItsMinimum() {
        let layout = make(total: 1400, splitPct: 15)
        XCTAssertEqual(layout.sessions, PanelLayout.minSessions)
    }

    func testTerminalKeepsItsReserveWhenTheListGrows() {
        let layout = make(total: 1400, splitPct: 80)
        XCTAssertGreaterThanOrEqual(layout.terminal, PanelLayout.minTerminal,
                                    "terminal must keep its minimum when session list is at maximum")

        // Worst-case regression guard: inspector at max, split at max
        let worst = make(total: 1400, splitPct: 80, sbWidth: 600)
        XCTAssertGreaterThanOrEqual(worst.terminal, PanelLayout.minTerminal,
                                    "terminal reserve must account for inspector width")
    }

    func testNarrowWindowNeverOverflowsTheCards() {
        let layout = make(total: 500)
        XCTAssertGreaterThanOrEqual(layout.terminal, 0)
        XCTAssertLessThanOrEqual(layout.sessions + layout.inspector, layout.inner)
    }

    func testDraggingTheSplitReturnsTheWidthUnderTheCursor() {
        let layout = make(total: 1400)
        let wanted: CGFloat = 500
        let pct = PanelLayout.splitPercent(dragX: Tokens.edge + wanted, inner: layout.inner)
        let after = make(total: 1400, splitPct: pct)
        XCTAssertEqual(after.sessions, wanted, accuracy: 8,
                       "the divider must land under the cursor, not a gutter away")
    }

    func testInspectorDragMeasuresFromTheRightEdge() {
        let total: CGFloat = 1400
        XCTAssertEqual(PanelLayout.inspectorWidth(dragX: total - Tokens.edge - 300,
                                                  total: total), 300)
    }

    func testHiddenSessionListFreesWidthToTerminal() {
        let layout = make(total: 1400, sessions: false)
        XCTAssertEqual(layout.sessions, 0)
        XCTAssertEqual(layout.inner, 1400 - Tokens.edge * 2 - Tokens.gutter,
                       "hiding sessions drops its gutter from the count")
        XCTAssertEqual(layout.terminal + layout.inspector, layout.inner,
                       "freed width goes to terminal and inspector")
    }

    func testBothZonesHiddenDropsAllGutters() {
        let layout = make(total: 1400, sessions: false, inspector: false)
        XCTAssertEqual(layout.sessions, 0)
        XCTAssertEqual(layout.inspector, 0)
        XCTAssertEqual(layout.inner, 1400 - Tokens.edge * 2,
                       "no gutters when all zones are hidden")
        XCTAssertEqual(layout.terminal, layout.inner,
                       "terminal gets the full inner width")
    }
}
