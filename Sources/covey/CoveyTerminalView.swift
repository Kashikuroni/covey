import AppKit
import SwiftTerm

/// TerminalView that makes the mouse wheel work in alternate-buffer TUIs:
/// forwards wheel as SGR mouse reports when the app enabled mouse tracking,
/// or as arrow keys otherwise (iTerm2-style "alternate scroll"). Normal-buffer
/// sessions keep SwiftTerm's viewport scrolling.
final class CoveyTerminalView: TerminalView {
    enum WheelRoute { case viewport, mouseReport, arrows }

    /// Fired after the terminal switches between the normal and alternate
    /// buffer (e.g. entering/leaving vim); the chrome resets history mode.
    var onBufferSwitch: (() -> Void)?

    func wheelRoute() -> WheelRoute {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return .viewport }
        if case .off = terminal.mouseMode { return .arrows }
        return .mouseReport
    }

    // MacTerminalView seals scrollWheel (`public override`, not `open`), so wheel
    // events are intercepted with a local monitor before AppKit delivers them.
    private var wheelMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeWheelMonitor()
        } else if wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.deltaY != 0 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch self.wheelRoute() {
                case .viewport:
                    return event                    // TerminalView scrolls the viewport
                case .mouseReport:
                    self.sendWheelReport(deltaY: event.deltaY, at: point)
                    return nil
                case .arrows:
                    self.sendWheelArrows(deltaY: event.deltaY)
                    return nil
                }
            }
        }
    }

    deinit {
        removeWheelMonitor()
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferSwitch?()
    }

    func sendWheelReport(deltaY: CGFloat, at point: CGPoint) {
        let terminal = getTerminal()
        // Cell-level precision is enough for wheel reports; derive the grid
        // position from the view bounds to avoid SwiftTerm's internal metrics.
        let col = max(0, min(terminal.cols - 1,
                             Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
        let rawRow = Int(point.y / max(bounds.height, 1) * CGFloat(terminal.rows))
        let row = max(0, min(terminal.rows - 1,
                             isFlipped ? rawRow : terminal.rows - 1 - rawRow))
        let flags = terminal.encodeButton(button: deltaY > 0 ? 4 : 5,
                                          release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: flags, x: col, y: row)
    }

    func sendWheelArrows(deltaY: CGFloat) {
        let terminal = getTerminal()
        let up = deltaY > 0
        let seq: [UInt8] = terminal.applicationCursor
            ? [0x1b, 0x4f, up ? 0x41 : 0x42]    // SS3 A / SS3 B
            : [0x1b, 0x5b, up ? 0x41 : 0x42]    // CSI A / CSI B
        let count = max(1, min(5, Int(abs(deltaY).rounded())))
        var bytes = [UInt8]()
        bytes.reserveCapacity(count * 3)
        for _ in 0..<count { bytes += seq }
        send(bytes)
    }
}

/// Lines the viewport sits short of the live bottom, reconstructed from the
/// values of the public scroll callback (position == yDisp / maxScrollback).
func linesShortOfBottom(position: Double, yDisp: Int) -> Int {
    guard position > 0, position < 1 else { return 0 }
    return Int(((1 - position) * Double(yDisp) / position).rounded())
}
