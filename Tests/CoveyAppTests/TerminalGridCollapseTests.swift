import XCTest
import SwiftTerm
@testable import covey

/// Issue #2 — the agent pane sometimes renders as a 2-character strip.
///
/// Mechanism: SwiftTerm only skips its grid recompute when a frame is exactly
/// 0x0, so a layout pass with zero width and a real height floors the emulator
/// at MINIMUM_COLS (2). The resize gate drops the matching non-positive size,
/// so the session is never told and keeps painting full-width frames into a
/// 2-column emulator — every line hard-wraps to two characters. The normal
/// buffer reflows on the next widening, the alternate buffer (claude, codex)
/// does not, which is why the strip survives until the agent repaints.
final class TerminalGridCollapseTests: XCTestCase {
    final class Probe: TerminalViewDelegate {
        var sizes = [(cols: Int, rows: Int)]()
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            sizes.append((newCols, newRows))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func makeView() -> (CoveyTerminalView, Probe) {
        let view = CoveyTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let probe = Probe()
        view.terminalDelegate = probe
        return (view, probe)
    }

    private func widestRow(_ view: CoveyTerminalView) -> Int {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).reduce(0) { widest, row in
            let line = terminal.getScrollInvariantLine(row: row)?
                .translateToString(trimRight: true) ?? ""
            return max(widest, line.count)
        }
    }

    // MARK: - The emulator's floor (why the guard exists)

    func testEmulatorFloorsAtTwoColumnsAndAlternateBufferNeverReflows() {
        let terminal = Terminal(delegate: HeadlessTerminalDelegate(),
                                options: TerminalOptions(cols: 139, rows: 40))
        terminal.feed(text: "\u{1b}[?1049h")            // alternate buffer
        terminal.resize(cols: -1, rows: 40)             // what a zero-width frame asks for

        XCTAssertEqual(terminal.cols, 2, "SwiftTerm floors the grid instead of refusing")

        terminal.feed(text: "recent commits gpt-5.6-sol high")
        terminal.resize(cols: 139, rows: 40)

        let widest = (0..<terminal.rows).reduce(0) { widest, row in
            max(widest, terminal.getScrollInvariantLine(row: row)?
                .translateToString(trimRight: true).count ?? 0)
        }
        XCTAssertEqual(widest, 2, "the alternate buffer keeps the 2-column wrap")
    }

    // MARK: - The guard

    func testDegenerateLayoutLeavesTheGridAlone() {
        let (view, probe) = makeView()
        let cols = view.getTerminal().cols
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(cols, 100)

        view.setFrameSize(NSSize(width: 0, height: 800))

        XCTAssertEqual(view.getTerminal().cols, cols)
        XCTAssertEqual(view.getTerminal().rows, rows)
        XCTAssertTrue(probe.sizes.isEmpty, "the session is never told about a collapsed grid")
    }

    func testZeroHeightLayoutLeavesTheGridAlone() {
        let (view, probe) = makeView()
        let rows = view.getTerminal().rows

        view.setFrameSize(NSSize(width: 1200, height: 0))

        XCTAssertEqual(view.getTerminal().rows, rows)
        XCTAssertTrue(probe.sizes.isEmpty)
    }

    func testAgentOutputSurvivesADegenerateLayoutPass() {
        let (view, _) = makeView()
        view.feed(text: "\u{1b}[?1049h")                // claude/codex live here
        view.setFrameSize(NSSize(width: 0, height: 800))
        view.feed(text: "recent commits gpt-5.6-sol high")
        view.setFrameSize(NSSize(width: 1200, height: 800))

        XCTAssertEqual(widestRow(view), 31, "no 2-column strip: the line stayed whole")
    }

    // MARK: - Session output before the pane is laid out

    func testZeroFrameViewMountsAtTheEmulatorFloor() {
        // How TerminalRepresentable.makeNSView creates every pane. The scroller
        // width makes the measured width negative, so SwiftTerm's "no size yet"
        // short-circuit (an exactly 0x0 frame) never fires and the grid floors.
        let view = CoveyTerminalView(frame: .zero)

        XCTAssertEqual(view.getTerminal().cols, 2)
        XCTAssertEqual(view.getTerminal().rows, 1)
    }

    func testSessionOutputWaitsForThePaneGrid() {
        let view = CoveyTerminalView(frame: .zero)
        let line = String(repeating: "x", count: 120)

        view.feed(sessionBytes: Array("\u{1b}[?1049h\(line)".utf8)[...])
        XCTAssertEqual(widestRow(view), 0, "nothing reaches a 2-column emulator")

        view.setFrameSize(NSSize(width: 1200, height: 800))

        XCTAssertEqual(widestRow(view), 120, "the replay wrapped at the pane's width")
    }

    func testSessionOutputAfterTheFirstLayoutIsNotHeld() {
        let (view, _) = makeView()

        view.feed(sessionBytes: Array("hello".utf8)[...])

        XCTAssertEqual(widestRow(view), 5)
    }

    func testHeldOutputSurvivesADegenerateFirstLayoutPass() {
        let view = CoveyTerminalView(frame: .zero)
        view.feed(sessionBytes: Array("\u{1b}[?1049h\(String(repeating: "x", count: 120))".utf8)[...])

        view.setFrameSize(NSSize(width: 0, height: 800))     // swallowed, still no grid
        XCTAssertEqual(widestRow(view), 0)

        view.setFrameSize(NSSize(width: 1200, height: 800))
        XCTAssertEqual(widestRow(view), 120)
    }

    func testNarrowButUsablePaneStillResizes() {
        let (view, probe) = makeView()

        view.setFrameSize(NSSize(width: 120, height: 800))   // the split's minimum pane

        XCTAssertGreaterThan(view.getTerminal().cols, 2)
        XCTAssertEqual(probe.sizes.last?.cols, view.getTerminal().cols)
    }
}

/// Terminal requires a delegate; none of it matters here.
private final class HeadlessTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
