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
        // `splitPercent` rounds to the nearest whole percent, so it can be off
        // by at most 0.5 percentage points from the exact value under the
        // cursor. Converting that back to a width multiplies by `inner`/100,
        // so the provable worst case is inner * 0.005 = 1368 * 0.005 = 6.84pt
        // (inner = 1400 - edge*2 - gutter*2 = 1368 with both zones shown).
        // 7 is the tightest whole-point bound that still covers it.
        XCTAssertEqual(after.sessions, wanted, accuracy: 7,
                       "the divider must land under the cursor, not a gutter away")
    }

    /// Regression guard for the case where a wide `sbWidth` combined with a
    /// wide `splitPct` used to hand the terminal exactly zero width (the
    /// inspector wasn't capped against it) — `CoveyTerminalView` holds output
    /// in an uncapped buffer until it gets a real grid, so that's a silent
    /// dead end rather than a visible squeeze.
    func testTerminalNeverStarvesAcrossWindowSizes() {
        for width in stride(from: CGFloat(400), through: 2000, by: 25) {
            for splitPct in [PanelLayout.minSessionSplitPercent, 38,
                             PanelLayout.maxSessionSplitPercent] {
                for sbWidth in [PanelLayout.minInspectorWidth, 360,
                                PanelLayout.maxInspectorWidth] {
                    let layout = make(total: width, splitPct: splitPct, sbWidth: sbWidth)
                    XCTAssertGreaterThan(layout.terminal, 0,
                        "terminal starved at width \(width), splitPct \(splitPct), sbWidth \(sbWidth)")
                }
            }
        }
    }

    func testWideWindowsCanUseNewSidebarMaxima() {
        let sessions = make(total: 6000, inspector: false,
                            splitPct: PanelLayout.maxSessionSplitPercent)
        XCTAssertEqual(sessions.sessions, sessions.inner * 0.90, accuracy: 0.001)

        let inspector = make(total: 2500, sessions: false,
                             sbWidth: PanelLayout.maxInspectorWidth)
        XCTAssertEqual(inspector.inspector, 1200)
        XCTAssertGreaterThanOrEqual(inspector.terminal, PanelLayout.minTerminalSliver)
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
