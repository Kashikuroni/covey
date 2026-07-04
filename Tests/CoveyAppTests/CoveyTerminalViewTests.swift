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

    func testBufferSwitchCallbackFires() {
        let (view, _) = makeView()
        var switches = 0
        view.onBufferSwitch = { switches += 1 }
        view.feed(text: "\u{1b}[?1049h")
        XCTAssertEqual(switches, 1)
        view.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(switches, 2)
    }

    func testLinesShortOfBottom() {
        // 186-line scrollback: yDisp 185 of 186 is exactly one line short.
        XCTAssertEqual(linesShortOfBottom(position: 185.0 / 186.0, yDisp: 185), 1)
        XCTAssertEqual(linesShortOfBottom(position: 184.0 / 186.0, yDisp: 184), 2)
        XCTAssertEqual(linesShortOfBottom(position: 0.5, yDisp: 93), 93)
    }

    @MainActor
    func testAltBufferScrollEventsClearHistoryMode() async throws {
        // Terminal.scroll() notifies unconditionally; in the alternate buffer
        // scrollPosition is 0, which must NOT light the HISTORY badge.
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let coordinator = TerminalRepresentable.Coordinator(model: model, name: "s-1")
        let (view, _) = makeView()
        view.feed(text: "\u{1b}[?1049h")   // enter the alternate buffer
        model.setHistoryMode(true)          // stale badge from a prior shell scroll
        coordinator.scrolled(source: view, position: 0)
        _ = await eventually { model.historyMode == false }
        XCTAssertFalse(model.historyMode)
    }

    func testScrollToPositionOneLandsExactBottom() {
        let (view, probe) = makeView()
        var text = ""
        for i in 0..<200 { text += "line \(i)\r\n" }
        view.feed(text: text)
        view.scroll(toPosition: 0.997)   // truncation repro: lands short of bottom
        XCTAssertLessThan(view.scrollPosition, 1.0)
        view.scroll(toPosition: 1.0)     // the snap target: exact bottom
        XCTAssertEqual(view.scrollPosition, 1.0)
        XCTAssertEqual(probe.positions.last, 1.0)
    }
}
