import XCTest
import SwiftTerm
@testable import covey

final class CoveyTerminalViewTests: XCTestCase {
    final class Probe: TerminalViewDelegate {
        var sent = [UInt8]()
        var positions = [Double]()
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += Array(data) }
        func scrolled(source: TerminalView, position: Double) { positions.append(position) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeView() -> (CoveyTerminalView, Probe) {
        let view = CoveyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let probe = Probe()
        view.terminalDelegate = probe
        return (view, probe)
    }

    func testRouteViewportInNormalBuffer() {
        let (view, _) = makeView()
        XCTAssertEqual(view.wheelRoute(), .viewport)
    }

    func testRouteArrowsInAltBufferWithoutMouse() {
        let (view, _) = makeView()
        view.feed(text: "\u{1b}[?1049h")
        XCTAssertEqual(view.wheelRoute(), .arrows)
    }

    func testRouteMouseReportInAltBufferWithMouse() {
        let (view, _) = makeView()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h")
        XCTAssertEqual(view.wheelRoute(), .mouseReport)
    }

    func testWheelReportSendsSGRWheelCodes() {
        let (view, probe) = makeView()
        // Alt buffer + SGR encoding + button tracking, like a real TUI.
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h")
        view.sendWheelReport(deltaY: 3, at: CGPoint(x: 10, y: 10))
        let up = String(decoding: probe.sent, as: UTF8.self)
        XCTAssertTrue(up.contains("\u{1b}[<64;"), "wheel-up SGR code expected, got: \(up)")
        probe.sent.removeAll()
        view.sendWheelReport(deltaY: -3, at: CGPoint(x: 10, y: 10))
        let down = String(decoding: probe.sent, as: UTF8.self)
        XCTAssertTrue(down.contains("\u{1b}[<65;"), "wheel-down SGR code expected, got: \(down)")
    }

    func testWheelArrowsPlainAndApplicationCursor() {
        let (view, probe) = makeView()
        view.feed(text: "\u{1b}[?1049h")
        view.sendWheelArrows(deltaY: 1)
        XCTAssertEqual(probe.sent, Array("\u{1b}[A".utf8))
        probe.sent.removeAll()
        view.sendWheelArrows(deltaY: -1)
        XCTAssertEqual(probe.sent, Array("\u{1b}[B".utf8))
        probe.sent.removeAll()
        view.feed(text: "\u{1b}[?1h")   // DECCKM: application cursor keys
        view.sendWheelArrows(deltaY: 1)
        XCTAssertEqual(probe.sent, Array("\u{1b}OA".utf8))
    }

    func testWheelArrowsRepeatCappedAtFiveAndFloorOne() {
        let (view, probe) = makeView()
        view.feed(text: "\u{1b}[?1049h")
        view.sendWheelArrows(deltaY: 40)
        XCTAssertEqual(probe.sent.count, 3 * 5, "capped at 5 arrows per event")
        probe.sent.removeAll()
        view.sendWheelArrows(deltaY: 0.3)
        XCTAssertEqual(probe.sent.count, 3, "at least 1 arrow per event")
    }
}
