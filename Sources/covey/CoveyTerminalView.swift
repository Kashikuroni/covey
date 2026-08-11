import AppKit
import SwiftTerm

private final class FileDropBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

/// TerminalView that makes the mouse wheel work in alternate-buffer TUIs:
/// forwards wheel as SGR mouse reports when the app enabled mouse tracking,
/// or as arrow keys otherwise (iTerm2-style "alternate scroll"). Normal-buffer
/// sessions keep SwiftTerm's viewport scrolling.
final class CoveyTerminalView: TerminalView {
    enum WheelRoute { case viewport, mouseReport, arrows }

    /// Fired after the terminal switches between the normal and alternate
    /// buffer (e.g. entering/leaving vim); the chrome resets history mode.
    var onBufferSwitch: (() -> Void)?

    /// Fired when pointer interaction requests pane focus. A focusing click is
    /// swallowed; a successful file drop also uses this path.
    var onFocusRequest: (() -> Void)?

    /// Fired after a wheel event scrolled a TUI (mouse-report / arrow route) so
    /// the host can kick the child into a full repaint.
    var onWheelScroll: (() -> Void)?

    /// Session name, for the issue #2 layout diagnostic only.
    var logName: String = "?"
    private var lastLogged: (w: CGFloat, cols: Int)?
    private var stateTimer: Timer?
    private var lastState: String?

    private(set) var isFileDropTarget = false
    private var registeredForFileDrops = false
    private lazy var fileDropBorderView: NSView = {
        let view = FileDropBorderView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        return view
    }()

    func wheelRoute() -> WheelRoute {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return .viewport }
        if case .off = terminal.mouseMode { return .arrows }
        return .mouseReport
    }

    private var wheelAccumulator = WheelAccumulator()

    /// Precise viewport scrolling for the normal buffer: trackpad pixels
    /// accumulate into whole lines (momentum events arrive through the
    /// same path, so inertia comes from macOS for free); a discrete
    /// mouse-wheel notch scrolls the Terminal.app-standard 3 lines.
    func scrollViewport(deltaY: CGFloat, precise: Bool) {
        let lines: Int
        if precise {
            let rowHeight = getOptimalFrameSize().height
                / CGFloat(getTerminal().rows)
            lines = wheelAccumulator.add(pixels: deltaY, rowHeight: rowHeight)
        } else {
            lines = deltaY > 0 ? 3 : -3
        }
        if lines > 0 { scrollUp(lines: lines) }
        else if lines < 0 { scrollDown(lines: -lines) }
    }

    /// Monitor body, extracted for tests: raw AppKit deltas in, one routed
    /// action out. TUI routes (mouseReport/arrows) use the legacy line delta
    /// and must IGNORE events where it rounds to zero: a trackpad momentum
    /// tail emits ~1s of such events, and mapping their sign naively turns
    /// them into a burst of wheel-DOWN reports that yanks a fresh upward
    /// scroll in claude's chat straight back to the bottom.
    func routeWheel(deltaY: CGFloat, scrollingDeltaY: CGFloat,
                    precise: Bool, at point: CGPoint) {
        switch wheelRoute() {
        case .viewport:
            scrollViewport(deltaY: precise ? scrollingDeltaY : deltaY,
                           precise: precise)
        case .mouseReport:
            // A trackpad reports sub-line pixels in `scrollingDeltaY` while the
            // legacy `deltaY` rounds to 0, so gating a wheel report on `deltaY`
            // dropped nearly every trackpad event and the TUI never scrolled.
            // Accumulate pixels into whole lines (same as viewport) and emit one
            // report per line — smooth, and momentum stays in the flick's sign.
            let lines = wheelLines(precise: precise, deltaY: deltaY,
                                   scrollingDeltaY: scrollingDeltaY)
            if lines != 0 { sendWheelReport(lines: lines, at: point) }
        case .arrows:
            if deltaY != 0 { sendWheelArrows(deltaY: deltaY) }
        }
    }

    /// Whole terminal lines a wheel event should advance: accumulated pixels for
    /// a trackpad, a fixed 3-line notch for a discrete mouse wheel.
    private func wheelLines(precise: Bool, deltaY: CGFloat,
                            scrollingDeltaY: CGFloat) -> Int {
        guard precise else { return deltaY > 0 ? 3 : (deltaY < 0 ? -3 : 0) }
        let rowHeight = getOptimalFrameSize().height / CGFloat(getTerminal().rows)
        return wheelAccumulator.add(pixels: scrollingDeltaY, rowHeight: rowHeight)
    }

    // MacTerminalView seals scrollWheel (`public override`, not `open`), so wheel
    // events are intercepted with a local monitor before AppKit delivers them.
    private var wheelMonitor: Any?
    private var mouseMonitor: Any?
    private var swallowNextMouseUp = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !registeredForFileDrops {
            registerForDraggedTypes([.fileURL])
            registeredForFileDrops = true
        }
        if window == nil {
            removeWheelMonitor()
            stopStateSampler()
        } else if wheelMonitor == nil {
            startStateSampler()
            installMouseMonitor()
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      event.deltaY != 0 || event.scrollingDeltaY != 0 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.routeWheel(deltaY: event.deltaY,
                                scrollingDeltaY: event.scrollingDeltaY,
                                precise: event.hasPreciseScrollingDeltas,
                                at: point)
                return nil
            }
        }
    }

    deinit {
        removeWheelMonitor()
        stateTimer?.invalidate()
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // A click on an unfocused terminal must only focus it: with mouse
    // reporting active the TUI would receive the click too (e.g. a link
    // under the cursor opens). Swallow the focusing down AND its up.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Bare motion: SwiftTerm's mouseMoved forwards it to the app WITHOUT
            // honoring allowMouseReporting, so hovering a keyboard-first claude
            // pane would move/select the mouse-interactive prompt. Swallow it.
            if event.type == .mouseMoved {
                guard !self.allowMouseReporting else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                return self.bounds.contains(point) ? nil : event
            }
            if event.type == .leftMouseUp, self.swallowNextMouseUp {
                self.swallowNextMouseUp = false
                return nil
            }
            guard event.type == .leftMouseDown else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            guard self.window?.firstResponder !== self else { return event }
            self.window?.makeFirstResponder(self)
            self.onFocusRequest?()
            self.swallowNextMouseUp = true
            return nil
        }
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferSwitch?()
    }

    /// False until `init` returns: SwiftTerm sizes the view while it is still
    /// building the emulator, and the guard below reads it.
    private var isSetUp = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isSetUp = true
        // A view built at a usable size already has its grid; one built at
        // `.zero` (how panes mount) waits for the first layout pass.
        hasPaneGrid = !collapsesGrid(frame.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // SwiftTerm recomputes its grid for every frame that is not exactly 0x0 and
    // floors the result at 2 columns / 1 row. A layout pass that hands the pane
    // a zero width but a real height therefore collapses the emulator to a
    // 2-column grid — while the resize gate refuses to forward the matching
    // non-positive size to the session, so the agent keeps painting full-width
    // frames into a 2-column emulator and every line hard-wraps to a
    // 2-character strip. The normal buffer reflows when the pane widens again;
    // the alternate buffer, where claude and codex live, does not, so the strip
    // survives until the agent repaints by itself (issue #2: "switch sessions a
    // few times and it fixes itself"). Swallowing the degenerate frame — 0x0 is
    // the one size SwiftTerm itself ignores — keeps the emulator on the last
    // grid the session was actually told about.
    override func setFrameSize(_ newSize: NSSize) {
        guard isSetUp else {
            super.setFrameSize(newSize)
            return
        }
        guard !collapsesGrid(newSize) else {
            PaneLayoutLog.note("degenerate", [
                ("name", logName),
                ("w", newSize.width), ("h", newSize.height),
                ("cols", getTerminal().cols), ("rows", getTerminal().rows),
            ])
            super.setFrameSize(.zero)
            return
        }
        super.setFrameSize(newSize)
        adoptPaneGrid()
    }

    /// Session output waiting for the pane's real grid, oldest first.
    private var pendingSessionBytes: [UInt8] = []
    private var hasPaneGrid = false

    /// Feeds session output, or holds it until the pane has been laid out.
    ///
    /// A view mounts as `frame: .zero`, and SwiftTerm sizes the emulator to its
    /// floor — 2 columns by 1 row — for that frame too: `getEffectiveWidth`
    /// subtracts the scroller, so the width it measures is negative and the
    /// "no size yet" short-circuit (an exactly 0x0 frame) never fires. Bytes
    /// fed in that window — the attach backfill flushes the moment the sink is
    /// registered, inside `makeNSView` — hard-wrap to a 2-character strip, and
    /// the alternate buffer does not reflow when the first layout pass widens
    /// the grid. That is issue #2, and it is why it comes and goes: it depends
    /// on whether the replay beats the layout pass.
    func feed(sessionBytes bytes: ArraySlice<UInt8>) {
        guard hasPaneGrid else {
            pendingSessionBytes.append(contentsOf: bytes)
            return
        }
        feed(byteArray: bytes)
    }

    /// The pane has a real grid now: release anything held back.
    private func adoptPaneGrid() {
        hasPaneGrid = true
        guard !pendingSessionBytes.isEmpty else { return }
        let held = pendingSessionBytes
        pendingSessionBytes = []
        feed(byteArray: held[...])
    }

    /// Mirrors SwiftTerm's own grid arithmetic: would this frame produce fewer
    /// columns or rows than the emulator's floor, i.e. a grid the session can
    /// never be resized to?
    private func collapsesGrid(_ size: NSSize) -> Bool {
        let terminal = getTerminal()
        let optimal = getOptimalFrameSize()
        let scroller = NSScroller.scrollerWidth(for: .regular,
                                                scrollerStyle: NSScroller.preferredScrollerStyle)
        let cellWidth = (optimal.width - scroller) / CGFloat(max(terminal.cols, 1))
        let cellHeight = optimal.height / CGFloat(max(terminal.rows, 1))
        guard cellWidth > 0, cellHeight > 0 else { return false }
        return size.width - scroller < cellWidth * 2 || size.height < cellHeight
    }

    // SwiftTerm lays its legacy scroller out at the .regular width (~15pt)
    // and the property is private — re-shape it after every layout pass to
    // a .mini strip hugging the right edge.
    override func layout() {
        super.layout()
        logLayout()
        for case let scroller as NSScroller in subviews {
            AppScrollerStyle.apply(to: scroller)
            let width = NSScroller.scrollerWidth(for: .mini, scrollerStyle: .legacy)
            scroller.frame = NSRect(x: bounds.width - width, y: scroller.frame.minY,
                                    width: width, height: scroller.frame.height)
        }
        if fileDropBorderView.superview != nil {
            fileDropBorderView.frame = bounds
            addSubview(fileDropBorderView, positioned: .above, relativeTo: nil)
        }
    }

    /// Issue #2 diagnostic: samples the emulator's own state every 2s, to
    /// confirm the `setFrameSize` guard holds in a real run. `maxLen` — the
    /// widest non-empty row — is the wrap width the content really has, so a
    /// `maxLen` of 2 against a wide `cols` is the strip coming back.
    private func logState() {
        let terminal = getTerminal()
        let buffer = terminal.buffer
        var maxLen = 0
        var sample = ""
        for row in 0..<terminal.rows {
            let s = terminal.getScrollInvariantLine(row: row)?
                .translateToString(trimRight: true) ?? ""
            maxLen = max(maxLen, s.count)
            if sample.isEmpty, !s.isEmpty { sample = String(s.prefix(48)) }
        }
        let key = "\(terminal.cols)/\(terminal.rows)/\(buffer.marginLeft)/"
            + "\(buffer.marginRight)/\(buffer.scrollTop)/\(buffer.scrollBottom)/"
            + "\(terminal.isCurrentBufferAlternate)/\(maxLen)"
        guard key != lastState else { return }
        lastState = key
        PaneLayoutLog.note("state", [
            ("name", logName),
            ("cols", terminal.cols), ("rows", terminal.rows),
            ("marginL", buffer.marginLeft), ("marginR", buffer.marginRight),
            ("scrollTop", buffer.scrollTop), ("scrollBot", buffer.scrollBottom),
            ("cx", buffer.x), ("cy", buffer.y),
            ("alt", terminal.isCurrentBufferAlternate),
            ("maxLen", maxLen),
            ("row", PaneLayoutLog.sanitize(sample)),
        ])
    }

    private func startStateSampler() {
        guard stateTimer == nil else { return }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logState() }
        }
    }

    private func stopStateSampler() {
        stateTimer?.invalidate()
        stateTimer = nil
    }

    /// Issue #2 diagnostic: one line per layout pass whose width or grid moved.
    private func logLayout() {
        let terminal = getTerminal()
        let width = bounds.width
        if let last = lastLogged, last.w == width, last.cols == terminal.cols { return }
        lastLogged = (width, terminal.cols)
        PaneLayoutLog.note("layout", [
            ("name", logName),
            ("w", width),
            ("h", bounds.height),
            ("cols", terminal.cols),
            ("rows", terminal.rows),
            ("win", window?.frame.width ?? -1),
            ("up", PaneLayoutLog.ancestry(self)),
            ("live", window?.inLiveResize == true),
        ])
    }

    func localFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL] ?? []
        return objects.map { $0 as URL }.filter(\.isFileURL)
    }

    @discardableResult
    func updateFileDropTarget(from pasteboard: NSPasteboard) -> Bool {
        let accepts = !localFileURLs(in: pasteboard).isEmpty
        setFileDropTarget(accepts)
        return accepts
    }

    func clearFileDropTarget() {
        setFileDropTarget(false)
    }

    private func setFileDropTarget(_ active: Bool) {
        isFileDropTarget = active
        if fileDropBorderView.superview == nil {
            addSubview(fileDropBorderView)
        }
        fileDropBorderView.isHidden = !active
        fileDropBorderView.needsDisplay = active
    }

    @discardableResult
    func performFileDrop(from pasteboard: NSPasteboard) -> Bool {
        defer { clearFileDropTarget() }
        let paths = localFileURLs(in: pasteboard).map(\.path)
        guard !paths.isEmpty else { return false }
        let delivered = sendDroppedPaths(paths)
        if !delivered { NSSound.beep() }
        return delivered
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDropTarget(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDropTarget(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearFileDropTarget()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performFileDrop(from: sender.draggingPasteboard)
    }

    /// Emit `|lines|` SGR wheel reports (button 4 up / 5 down) to the TUI.
    func sendWheelReport(lines: Int, at point: CGPoint) {
        guard lines != 0 else { return }
        let terminal = getTerminal()
        // Cell-level precision is enough for wheel reports; derive the grid
        // position from the view bounds to avoid SwiftTerm's internal metrics.
        let col = max(0, min(terminal.cols - 1,
                             Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
        let rawRow = Int(point.y / max(bounds.height, 1) * CGFloat(terminal.rows))
        let row = max(0, min(terminal.rows - 1,
                             isFlipped ? rawRow : terminal.rows - 1 - rawRow))
        let flags = terminal.encodeButton(button: lines > 0 ? 4 : 5,
                                          release: false, shift: false, meta: false, control: false)
        for _ in 0..<min(abs(lines), 8) {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
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

    /// Writes Finder-dropped paths as shell-safe arguments without executing
    /// the command. Each path is its own bracketed-paste unit when the child
    /// application has enabled bracketed paste mode.
    @discardableResult
    func sendDroppedPaths(_ paths: [String]) -> Bool {
        let accepted = paths.compactMap(shellQuotedTerminalPath)
        guard !accepted.isEmpty else { return false }

        window?.makeFirstResponder(self)
        onFocusRequest?()

        let bracketed = getTerminal().bracketedPasteMode
        for (index, path) in accepted.enumerated() {
            if index > 0 { send([0x20]) }
            if bracketed { send(EscapeSequences.bracketedPasteStart) }
            send(Array(path.utf8))
            if bracketed { send(EscapeSequences.bracketedPasteEnd) }
        }
        return true
    }
}

/// Lines the viewport sits short of the live bottom, reconstructed from the
/// values of the public scroll callback (position == yDisp / maxScrollback).
func linesShortOfBottom(position: Double, yDisp: Int) -> Int {
    guard position > 0, position < 1 else { return 0 }
    return Int(((1 - position) * Double(yDisp) / position).rounded())
}
