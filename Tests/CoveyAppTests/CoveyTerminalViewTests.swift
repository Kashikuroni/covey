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

    private func filePasteboard(_ urls: [URL]) -> NSPasteboard {
        let name = NSPasteboard.Name("covey-file-drop-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        return pasteboard
    }

    private func fillScrollback(_ view: CoveyTerminalView, lines: Int = 200) {
        for i in 0..<lines { view.feed(text: "line \(i)\r\n") }
    }

    func testPreciseDeltasScrollOneLinePerRowHeight() {
        let (view, _) = makeView()
        fillScrollback(view)
        let bottom = view.getTerminal().buffer.yDisp
        let rowHeight = view.getOptimalFrameSize().height
            / CGFloat(view.getTerminal().rows)
        view.scrollViewport(deltaY: rowHeight * 0.5, precise: true)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom)     // sub-line: no move
        view.scrollViewport(deltaY: rowHeight * 0.6, precise: true)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 1) // crossed one row
    }

    // Regression: the slice-9 "one line short of bottom" snap (scroller-drag
    // truncation fix) must NOT fire for wheel scrolling — it yanked a slow
    // one-line scroll straight back to the bottom, and inline claude's
    // constant repaints re-fired it with a visible delay.
    @MainActor
    func testWheelScrollOneLineFromBottomIsNotSnappedBack() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        let coordinator = TerminalRepresentable.Coordinator(model: model, name: "s")
        let view = CoveyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.terminalDelegate = coordinator
        fillScrollback(view)
        let bottom = view.getTerminal().buffer.yDisp
        let rowHeight = view.getOptimalFrameSize().height
            / CGFloat(view.getTerminal().rows)
        view.scrollViewport(deltaY: rowHeight * 1.1, precise: true)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 1)
        // Let a wrongly-scheduled async snap run, then re-check the position.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 1)
    }

    // Regression: momentum-tail events (line delta rounded to 0, pixel delta
    // nonzero) must NOT reach the TUI as wheel reports — a zero delta maps
    // to the DOWN button and a ~1s burst of them scrolled claude's chat
    // back to the bottom after every flick.
    func testZeroLineDeltaSendsNoWheelReport() {
        let (view, probe) = makeView()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1003h")
        view.routeWheel(deltaY: 0, scrollingDeltaY: -4, precise: true,
                        at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(probe.sent.isEmpty)
        view.routeWheel(deltaY: 2, scrollingDeltaY: 20, precise: true,
                        at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(String(decoding: probe.sent, as: UTF8.self).contains("<64;"))
    }

    func testMouseNotchScrollsThreeLines() {
        let (view, _) = makeView()
        fillScrollback(view)
        let bottom = view.getTerminal().buffer.yDisp
        view.scrollViewport(deltaY: 1, precise: false)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom - 3)
        view.scrollViewport(deltaY: -1, precise: false)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom)
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
        view.sendWheelReport(lines: 3, at: CGPoint(x: 10, y: 10))
        let up = String(decoding: probe.sent, as: UTF8.self)
        XCTAssertTrue(up.contains("\u{1b}[<64;"), "wheel-up SGR code expected, got: \(up)")
        probe.sent.removeAll()
        view.sendWheelReport(lines: -3, at: CGPoint(x: 10, y: 10))
        let down = String(decoding: probe.sent, as: UTF8.self)
        XCTAssertTrue(down.contains("\u{1b}[<65;"), "wheel-down SGR code expected, got: \(down)")
    }

    // Regression: a trackpad reports pixels in scrollingDeltaY while deltaY
    // stays 0, so the mouse-report route must accumulate pixels — gating on
    // deltaY dropped every trackpad event and the TUI never scrolled.
    func testTrackpadWheelReportAccumulatesDespiteZeroLineDelta() {
        let (view, probe) = makeView()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1003h")  // alt + SGR + anyEvent
        let rowHeight = view.getOptimalFrameSize().height
            / CGFloat(view.getTerminal().rows)
        view.routeWheel(deltaY: 0, scrollingDeltaY: rowHeight * 0.4,
                        precise: true, at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(probe.sent.isEmpty, "sub-line trackpad delta must not emit yet")
        view.routeWheel(deltaY: 0, scrollingDeltaY: rowHeight * 0.8,
                        precise: true, at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(String(decoding: probe.sent, as: UTF8.self).contains("<64;"),
                      "an accumulated whole row must emit a wheel report")
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

    func testDroppedPathSendsQuotedTextWithoutBracketedPaste() {
        let (view, probe) = makeView()

        XCTAssertTrue(view.sendDroppedPaths(["/tmp/My File.png"]))
        XCTAssertEqual(probe.sent, Array("'/tmp/My File.png'".utf8))
    }

    func testFileDropReadsFilesAndDirectoriesInPasteboardOrder() {
        let (view, _) = makeView()
        let file = URL(fileURLWithPath: "/tmp/first image.png")
        let directory = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let pasteboard = filePasteboard([file, directory])

        XCTAssertEqual(view.localFileURLs(in: pasteboard), [file, directory])
    }

    func testUnsupportedPasteboardDoesNotBecomeDropTarget() {
        let (view, _) = makeView()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("covey-text-drop-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("not a file", forType: .string)

        XCTAssertFalse(view.updateFileDropTarget(from: pasteboard))
        XCTAssertFalse(view.isFileDropTarget)
    }

    func testMultipleDroppedPathsUseDistinctBracketedPasteUnits() {
        let (view, probe) = makeView()
        view.feed(text: "\u{1b}[?2004h")

        XCTAssertTrue(view.sendDroppedPaths([
            "/tmp/first image.png",
            "/tmp/second.png",
        ]))

        let expected = "\u{1b}[200~'/tmp/first image.png'\u{1b}[201~ "
            + "\u{1b}[200~'/tmp/second.png'\u{1b}[201~"
        XCTAssertEqual(probe.sent, Array(expected.utf8))
        XCTAssertFalse(probe.sent.contains(0x0d))
        XCTAssertFalse(probe.sent.contains(0x0a))
    }

    @MainActor
    func testDroppedPathsFocusOnlyWhenAtLeastOnePathIsSafe() {
        let (view, probe) = makeView()
        let window = hostTerminalForKeyboardInput(view)
        window.makeFirstResponder(nil)
        var focusRequests = 0
        view.onFocusRequest = { focusRequests += 1 }

        XCTAssertFalse(view.sendDroppedPaths([
            "relative.png",
            "/tmp/bad\nname.png",
        ]))
        XCTAssertEqual(focusRequests, 0)
        XCTAssertTrue(probe.sent.isEmpty)
        XCTAssertFalse(window.firstResponder === view)

        XCTAssertTrue(view.sendDroppedPaths([
            "/tmp/good.png",
            "/tmp/bad\nname.png",
        ]))
        XCTAssertEqual(focusRequests, 1)
        XCTAssertEqual(probe.sent, Array("'/tmp/good.png'".utf8))
        XCTAssertTrue(window.firstResponder === view)
    }

    @MainActor
    func testPerformFileDropSendsSafeSiblingsFocusesAndClearsFeedback() {
        let (view, probe) = makeView()
        let window = hostTerminalForKeyboardInput(view)
        window.makeFirstResponder(nil)
        var focusRequests = 0
        view.onFocusRequest = { focusRequests += 1 }
        let pasteboard = filePasteboard([
            URL(fileURLWithPath: "/tmp/first image.png"),
            URL(fileURLWithPath: "/tmp/bad\nname.png"),
            URL(fileURLWithPath: "/tmp/folder", isDirectory: true),
        ])

        XCTAssertTrue(view.updateFileDropTarget(from: pasteboard))
        XCTAssertTrue(view.isFileDropTarget)
        XCTAssertTrue(view.performFileDrop(from: pasteboard))

        XCTAssertEqual(
            probe.sent,
            Array("'/tmp/first image.png' '/tmp/folder'".utf8)
        )
        XCTAssertEqual(focusRequests, 1)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(view.isFileDropTarget)
        XCTAssertFalse(probe.sent.contains(0x0d))
        XCTAssertFalse(probe.sent.contains(0x0a))
    }

    @MainActor
    func testAllUnsafeFileDropFailsWithoutFocusOrBytes() {
        let (view, probe) = makeView()
        let window = hostTerminalForKeyboardInput(view)
        window.makeFirstResponder(nil)
        var focusRequests = 0
        view.onFocusRequest = { focusRequests += 1 }
        let pasteboard = filePasteboard([
            URL(fileURLWithPath: "/tmp/bad\nname.png"),
        ])

        XCTAssertTrue(view.updateFileDropTarget(from: pasteboard))
        XCTAssertFalse(view.performFileDrop(from: pasteboard))

        XCTAssertTrue(probe.sent.isEmpty)
        XCTAssertEqual(focusRequests, 0)
        XCTAssertFalse(window.firstResponder === view)
        XCTAssertFalse(view.isFileDropTarget)
    }

    func testClearingFileDropTargetModelsDragExitOrCancellation() {
        let (view, _) = makeView()
        let pasteboard = filePasteboard([
            URL(fileURLWithPath: "/tmp/image.png"),
        ])

        XCTAssertTrue(view.updateFileDropTarget(from: pasteboard))
        view.clearFileDropTarget()

        XCTAssertFalse(view.isFileDropTarget)
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

    @MainActor
    func testShiftEnterUsesCsiUWhenKittyDisambiguationIsActive() {
        let view = CoveyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let probe = TerminalInputProbe()
        view.terminalDelegate = probe
        let window = hostTerminalForKeyboardInput(view)
        XCTAssertTrue(window.firstResponder === view)

        view.feed(text: "\u{1b}[=1;1u")
        sendReturnKey(to: view, modifiers: [.shift])

        XCTAssertEqual(probe.sent, Array("\u{1b}[13;2u".utf8))
    }

    @MainActor
    func testPlainEnterRemainsCarriageReturnInKittyMode() {
        let view = CoveyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let probe = TerminalInputProbe()
        view.terminalDelegate = probe
        let window = hostTerminalForKeyboardInput(view)
        XCTAssertTrue(window.firstResponder === view)

        view.feed(text: "\u{1b}[=1;1u")
        sendReturnKey(to: view)

        XCTAssertEqual(probe.sent, [0x0d])
    }

    @MainActor
    func testShiftEnterKeepsLegacyBehaviorWithoutKittyMode() {
        let view = CoveyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let probe = TerminalInputProbe()
        view.terminalDelegate = probe
        let window = hostTerminalForKeyboardInput(view)
        XCTAssertTrue(window.firstResponder === view)

        sendReturnKey(to: view, modifiers: [.shift])

        XCTAssertEqual(probe.sent, [0x0d])
    }
}
