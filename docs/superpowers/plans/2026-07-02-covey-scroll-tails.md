# covey Scroll Tails + coveyd Tech Debt (Slice 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the mouse wheel work in alternate-buffer TUI sessions, unstick the HISTORY badge (scrollbar snap + buffer-switch reset), and close coveyd tech debt #5/#6/#7/#9.

**Architecture:** A `CoveyTerminalView` subclass of SwiftTerm's `TerminalView` routes wheel events by buffer/mouse-mode state using only public SwiftTerm API (no fork). The Coordinator gains a one-line-short snap and a buffer-switch history reset. CoveydCore gets a non-blocking `reap`, gap-free auto names, oversize-append clamping, and a `withEntry` helper. Spec: `docs/superpowers/specs/2026-07-02-covey-scroll-tails-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftTerm 1.13 (public API only), XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No network or thread `sleep` in tests; use `waitUntil`/`eventually`/expectations.
- Only public SwiftTerm API in covey (verified: `TerminalView` is `open`, `bufferActivated` is `open`, `isCurrentBufferAlternate`, `mouseMode`, `applicationCursor`, `cols`, `rows`, `encodeButton`, `sendEvent(buttonFlags:x:y:)`, `send(_:)`, `scroll(toPosition:)`, `scrollPosition`, `buffer.yDisp`, `getTerminal()` are public).
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Target>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- Full suite: `xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1`.

---

### Task 1: CoveyTerminalView — wheel routing

**Files:**
- Create: `Sources/covey/CoveyTerminalView.swift`
- Test: `Tests/CoveyAppTests/CoveyTerminalViewTests.swift`

**Interfaces:**
- Consumes: SwiftTerm public API (see Global Constraints).
- Produces (used by Task 2):
  - `final class CoveyTerminalView: TerminalView` with
    `enum WheelRoute { case viewport, mouseReport, arrows }`,
    `var onBufferSwitch: (() -> Void)?`,
    `func wheelRoute() -> WheelRoute`,
    `func sendWheelReport(deltaY: CGFloat, at point: CGPoint)`,
    `func sendWheelArrows(deltaY: CGFloat)`
  - `func linesShortOfBottom(position: Double, yDisp: Int) -> Int` (free function, same file)

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/CoveyTerminalView.swift`:

```swift
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

    func wheelRoute() -> WheelRoute { .viewport }

    func sendWheelReport(deltaY: CGFloat, at point: CGPoint) {}

    func sendWheelArrows(deltaY: CGFloat) {}
}

/// Lines the viewport sits short of the live bottom, reconstructed from the
/// values of the public scroll callback (position == yDisp / maxScrollback).
func linesShortOfBottom(position: Double, yDisp: Int) -> Int { 0 }
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/CoveyTerminalViewTests.swift`:

```swift
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
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.CoveyTerminalViewTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 6 tests, ≥5 failures (skeleton returns `.viewport` / does nothing).

- [ ] **Step 4: Implement**

Replace the three stub methods in `Sources/covey/CoveyTerminalView.swift`:

```swift
    func wheelRoute() -> WheelRoute {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return .viewport }
        if case .off = terminal.mouseMode { return .arrows }
        return .mouseReport
    }

    // NOTE (discovered during execution): MacTerminalView declares scrollWheel as
    // `public override`, NOT `open` — overriding it outside SwiftTerm does not
    // compile. Intercept wheel events with a local NSEvent monitor instead:
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
```

(`linesShortOfBottom` stays a stub until Task 2.)

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/CoveyTerminalView.swift Tests/CoveyAppTests/CoveyTerminalViewTests.swift
git commit -m "feat(covey): CoveyTerminalView — wheel routing for TUI sessions"
```

---

### Task 2: Scrollbar snap + buffer-switch history reset

**Files:**
- Modify: `Sources/covey/CoveyTerminalView.swift`
- Modify: `Sources/covey/TerminalController.swift`
- Test: `Tests/CoveyAppTests/CoveyTerminalViewTests.swift` (append)

**Interfaces:**
- Consumes: `CoveyTerminalView`, `linesShortOfBottom` (Task 1); `AppModel.setHistoryMode(_:)` (slice 8).
- Produces: Coordinator snap + history reset; `TerminalRepresentable.makeNSView` returns a `CoveyTerminalView`.

- [ ] **Step 1: Write the failing tests (append to CoveyTerminalViewTests)**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.CoveyTerminalViewTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 9 tests, ≥2 failures (`onBufferSwitch` never fires, `linesShortOfBottom` returns 0). `testScrollToPositionOneLandsExactBottom` may already pass — it pins SwiftTerm behavior the snap relies on.

- [ ] **Step 3: Implement**

1. In `Sources/covey/CoveyTerminalView.swift`, add inside the class:

```swift
    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferSwitch?()
    }
```

2. Same file, replace the `linesShortOfBottom` stub:

```swift
func linesShortOfBottom(position: Double, yDisp: Int) -> Int {
    guard position > 0, position < 1 else { return 0 }
    return Int(((1 - position) * Double(yDisp) / position).rounded())
}
```

3. In `Sources/covey/TerminalController.swift`, replace `makeNSView`:

```swift
    func makeNSView(context: Context) -> TerminalView {
        let view = CoveyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        let model = self.model
        // Entering/leaving the alternate buffer invalidates any scrolled-up
        // viewport, so a stale HISTORY badge must clear.
        view.onBufferSwitch = { Task { @MainActor in model.setHistoryMode(false) } }
        applyTheme(to: view)
        model.onTerminalOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }
```

4. Same file, replace `Coordinator.scrolled`:

```swift
        func scrolled(source: TerminalView, position: Double) {
            // SwiftTerm's scroll(toPosition:) truncates, so a scrollbar drag can
            // land one line short of the live bottom and pin the HISTORY badge;
            // snap that last line (scroll(toPosition: 1.0) hits the exact bottom
            // and re-fires scrolled with 1.0).
            if linesShortOfBottom(position: position,
                                  yDisp: source.getTerminal().buffer.yDisp) == 1 {
                DispatchQueue.main.async { [weak source] in source?.scroll(toPosition: 1.0) }
                return
            }
            // position 1.0 == pinned to the live bottom; anything less is history.
            let history = position < 0.999
            Task { @MainActor in model.setHistoryMode(history) }
        }
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest -XCTest CoveyAppTests.CoveyTerminalViewTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: 9 tests 0 failures; full suite 0 failures.

- [ ] **Step 5: Partial smoke**

`swift run covey`: shell session → `seq 1 200` → drag the scrollbar knob hard to the bottom → HISTORY clears. Wheel up in a `less` session scrolls it. Quit ⌘Q.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/CoveyTerminalView.swift Sources/covey/TerminalController.swift Tests/CoveyAppTests/CoveyTerminalViewTests.swift
git commit -m "feat(covey): scrollbar bottom snap + history reset on buffer switch"
```

---

### Task 3: Reap semantics — #5 resolved as non-issue on macOS

> **Executed with a deviation.** Empirical probe (scratchpad `eofprobe.swift`):
> on macOS the pty master EOFs exactly when the session leader exits (tty
> revoke) — a grandchild holding every slave fd does not delay it (EOF in 7 ms
> with `sleep 2` still alive), and a live leader with all fds closed produces
> no EOF at all. `reap()` therefore only ever runs with the child already a
> zombie: the blocking `waitpid` cannot block. The planned exit-source
> machinery would be unreachable, untestable code — dropped per YAGNI.
> Delivered instead: a comment in `reap()` documenting the invariant and
> `testMasterEOFImpliesChildExited` pinning both directions.

**Files:**
- Modify: `Sources/CoveydCore/PTYProcess.swift`
- Test: `Tests/CoveydCoreTests/PTYProcessTests.swift`

**Interfaces:**
- Consumes: existing `PTYProcess` internals (`queue`, `pid`, `reaped`, `readSource`, `onExit`).
- Produces: same public API; `reap` never blocks the queue.

- [ ] **Step 1: Write the failing test (append to PTYProcessTests)**

```swift
    func testReapDoesNotBlockQueueWhenChildOutlivesTTY() throws {
        // The child detaches from the tty (master reads EOF) but keeps running.
        // reap() must not block the queue on waitpid: backfill is queue.sync and
        // would freeze — with the old blocking reap this test times out.
        let p = PTYProcess()
        let exitExp = expectation(description: "exit reported")
        p.setExitHandler { _ in exitExp.fulfill() }
        try p.spawn(argv: ["/bin/sh", "-c", "exec >/dev/null 2>&1 </dev/null; sleep 30"],
                    cols: 80, rows: 24)
        var polls = 0
        waitUntil({ _ = p.backfill(since: 0); polls += 1; return polls >= 10 },
                  "queue responsive after tty EOF")
        p.kill()   // SIGHUP the group; the exit source reaps the dead child
        wait(for: [exitExp], timeout: 5)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.PTYProcessTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed|error" | tail -3
```

Expected: the new test FAILS by timeout (queue blocked in `waitpid` for the sleeping child). Existing tests stay green.

- [ ] **Step 3: Implement**

In `Sources/CoveydCore/PTYProcess.swift`:

1. Add a field next to `readSource`:

```swift
    private var exitSource: DispatchSourceProcess?
```

2. Replace `reap()`:

```swift
    private func reap() {
        guard !reaped else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            finishReap(status: status)
            return
        }
        // EOF arrived but the child is still alive (it closed the tty and kept
        // running); a blocking waitpid here would freeze the queue — and kill(),
        // write(), backfill() with it. Reap on the actual exit instead.
        readSource?.cancel()
        guard exitSource == nil else { return }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        src.setEventHandler { [weak self] in self?.tryReapExited() }
        exitSource = src
        src.resume()
        // The child may have died between the poll above and arming the source;
        // poll once more so that window cannot strand a zombie.
        tryReapExited()
    }

    private func tryReapExited() {
        guard !reaped else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        finishReap(status: status)
    }

    private func finishReap(status: Int32) {
        reaped = true
        readSource?.cancel()
        exitSource?.cancel()
        exitSource = nil
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }
        onExit?(code)
    }
```

Note: `reaped` stays `false` while the child outlives the tty, so the SIGKILL escalation in `kill()` still fires for a child that ignores SIGHUP.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcrun xctest -XCTest CoveydCoreTests.PTYProcessTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: PTYProcessTests all green (new test finishes in ~1-2 s, not 30); full suite 0 failures.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveydCore/PTYProcess.swift Tests/CoveydCoreTests/PTYProcessTests.swift
git commit -m "fix(coveyd): non-blocking reap via process exit source"
```

---

### Task 4: Gap-free auto names (#6)

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift:31-37`
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: existing `SessionRegistry.create` signature (unchanged).
- Produces: auto names `s-1, s-2, …` without gaps; explicit names and failed creates never consume a number.

- [ ] **Step 1: Write the failing tests (append to SessionRegistryTests)**

```swift
    func testAutoNamesHaveNoGaps() throws {
        let reg = SessionRegistry()
        let a = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "explicit")
        XCTAssertThrowsError(
            try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "explicit"))
        let b = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        XCTAssertEqual(a.name, "s-1")
        XCTAssertEqual(b.name, "s-2",
                       "explicit names and failed creates must not consume auto numbers")
        for s in reg.list() { reg.kill(name: s.name) }
    }

    func testAutoNameSkipsExplicitCollision() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "s-1")
        let a = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        XCTAssertEqual(a.name, "s-2")
        for s in reg.list() { reg.kill(name: s.name) }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.SessionRegistryTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed|error:" | tail -3
```

Expected: both new tests FAIL (`b.name == "s-4"`, auto collides with `s-1`).

- [ ] **Step 3: Implement**

In `Sources/CoveydCore/SessionRegistry.swift`, inside `create`, replace

```swift
        lock.lock()
        counter += 1
        let id = name ?? "s-\(counter)"
        if entries[id] != nil {
            lock.unlock()
            throw RegistryError.duplicateName(id)
        }
```

with

```swift
        lock.lock()
        var autoNumber: Int?
        let id: String
        if let name {
            id = name
        } else {
            // Explicit names may occupy s-N; probe forward, commit only on success.
            var n = counter + 1
            while entries["s-\(n)"] != nil { n += 1 }
            autoNumber = n
            id = "s-\(n)"
        }
        if entries[id] != nil {
            lock.unlock()
            throw RegistryError.duplicateName(id)
        }
```

and after the successful `spawn`, before `entries[id] = (session, proc, screen)`, add:

```swift
        if let autoNumber { counter = autoNumber }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: SessionRegistryTests all green.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "fix(coveyd): auto session names without gaps"
```

---

### Task 5: Oversize append clamp (#7)

**Files:**
- Modify: `Sources/CoveydCore/ScrollbackBuffer.swift:18-31`
- Test: `Tests/CoveydCoreTests/ScrollbackBufferTests.swift`

**Interfaces:**
- Consumes: existing `ScrollbackBuffer` API (unchanged).
- Produces: `append` whose returned range never starts inside evicted bytes.

- [ ] **Step 1: Write the failing test (append to ScrollbackBufferTests)**

```swift
    func testOversizeAppendReturnsOnlySurvivingRange() {
        let buf = ScrollbackBuffer(limit: 8)
        let range = buf.append(Array("0123456789AB".utf8))   // 12 bytes, 8-byte ring
        XCTAssertEqual(range.to - range.from, 8, "range covers only surviving bytes")
        XCTAssertEqual(range.from, buf.headSeq)
        let (bytes, from, gapped) = buf.since(range.from)
        XCTAssertFalse(gapped, "an append's own range must not come back gapped")
        XCTAssertEqual(from, range.from)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "456789AB")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.ScrollbackBufferTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed|error:" | tail -3
```

Expected: new test FAILS (`range.from == 0` but `headSeq == 4` → gapped).

- [ ] **Step 3: Implement**

Replace `append` in `Sources/CoveydCore/ScrollbackBuffer.swift`:

```swift
    @discardableResult
    public func append(_ bytes: [UInt8]) -> (from: Int, to: Int) {
        // A chunk larger than the ring keeps only its tail. Advance tailSeq past
        // the dropped prefix first, so the returned range (and the seq handed to
        // output consumers) never starts inside evicted bytes.
        var chunk = bytes[...]
        if chunk.count > capacity {
            tailSeq += chunk.count - capacity
            chunk = chunk.suffix(capacity)
        }
        let from = tailSeq
        for byte in chunk {
            storage[tailSeq % capacity] = byte
            tailSeq += 1
        }
        count = min(count + chunk.count, capacity)
        headSeq = tailSeq - count
        return (from, tailSeq)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2, then the full suite. Expected: all green.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveydCore/ScrollbackBuffer.swift Tests/CoveydCoreTests/ScrollbackBufferTests.swift
git commit -m "fix(coveyd): clamp oversize scrollback append to ring capacity"
```

---

### Task 6: Dedup — `withEntry` + shared `expectOutput` (#9)

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift` (kill/write/resize/backfill)
- Modify: `Tests/CoveydCoreTests/TestSupport.swift`
- Modify: `Tests/CoveydCoreTests/PTYProcessTests.swift` (drop the private helper)

**Interfaces:**
- Consumes: existing tests (behavior must not change).
- Produces: `private func withEntry(_ name: String) -> (process: PTYProcess, screen: ScreenModel)?`; `XCTestCase.expectOutput(_:contains:)` in TestSupport.

- [ ] **Step 1: Refactor SessionRegistry**

Add below `get(name:)`:

```swift
    /// Snapshot of a session's process and screen under the lock; callers act
    /// on the pair outside it.
    private func withEntry(_ name: String) -> (process: PTYProcess, screen: ScreenModel)? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[name] else { return nil }
        return (entry.process, entry.screen)
    }
```

Replace the four lock-copy-unlock call sites:

```swift
    public func kill(name: String) {
        withEntry(name)?.process.kill()
    }
```

```swift
    public func write(name: String, bytes: [UInt8]) {
        withEntry(name)?.process.write(bytes)
    }
```

```swift
    public func resize(name: String, cols: UInt16, rows: UInt16) {
        guard let entry = withEntry(name) else { return }
        entry.process.resize(cols: cols, rows: rows)
        entry.screen.resize(cols: Int(cols), rows: Int(rows))
    }
```

```swift
    public func backfill(name: String, since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)? {
        withEntry(name)?.process.backfill(since: seq)
    }
```

- [ ] **Step 2: Move `expectOutput` into TestSupport**

In `Tests/CoveydCoreTests/TestSupport.swift`, add to the `extension XCTestCase`:

```swift
    /// Expectation that fulfills once the process's accumulated output
    /// contains `needle`.
    func expectOutput(_ p: PTYProcess, contains needle: String) -> XCTestExpectation {
        let exp = expectation(description: "output contains \(needle)")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.setOutputHandler { chunk, _ in
            collected += chunk
            if String(decoding: collected, as: UTF8.self).contains(needle) {
                exp.fulfill()
            }
        }
        return exp
    }
```

Add `@testable import CoveydCore` to TestSupport.swift's imports if not present. Delete the now-duplicate `private func expectOutput` from `Tests/CoveydCoreTests/PTYProcessTests.swift` (lines 5-18).

- [ ] **Step 3: Build + full suite (refactor gate: everything stays green)**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 4: Hand off commit to the user**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/TestSupport.swift Tests/CoveydCoreTests/PTYProcessTests.swift
git commit -m "refactor(coveyd): withEntry helper + shared expectOutput"
```

---

### Task 7a (inline fix): daemon deadlock on a wedged raw-mode child

> **Found during the smoke:** the app hung at "starting daemon…". `sample` of
> the daemon showed the full chain: `PTYProcess.write` blocked in kernel
> `write()` (raw-mode child stopped reading its tty → kernel input queue full),
> which wedged the `covey.pty` queue; `IPCServer.dispatch → backfill →
> queue.sync` on that queue wedged the IPC thread; every client request
> (including `list` from a fresh app) waited forever. `kill()` also runs on the
> wedged queue, so the session could not even be killed.
>
> Fix (same failure class as #5, but real): the master fd is now `O_NONBLOCK`
> with a capped `pendingInput` backlog drained by a write source (overflow is
> dropped like a full kernel queue); `ScrollbackBuffer` synchronizes internally
> and `backfill` no longer hops through the pty queue; the read loop tolerates
> `EAGAIN`/`EINTR`. Pinned by
> `PTYProcessTests.testWriteToStuckChildDoesNotWedgeQueue` (raw-mode `sleep`
> child + 256 KB write + responsive backfill + working kill).

- [ ] **Step 1: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 2: Manual smoke**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock
swift run covey
```

Verify:
1. claude session: mouse wheel scrolls claude's own chat; links still open only via claude.
2. `less` in a shell session (`seq 1 500 | less`): wheel scrolls the pager.
3. Plain shell: wheel scrolls the viewport as before; HISTORY appears on scroll-up, clears at the bottom.
4. Drag the scrollbar knob hard to the bottom → HISTORY clears.
5. Scroll a shell up (HISTORY on) → run `vim`, quit → no stale HISTORY badge.
6. Session whose child ignores the tty (`sh -c "exec >/dev/null 2>&1; sleep 30"`): kill it from the UI — the app stays responsive, the session disappears.

Fix any failure inline (each fix = its own user commit) and re-check.

- [ ] **Step 3: Hand off the plan/docs commit to the user**

```bash
git add docs/superpowers/plans/2026-07-02-covey-scroll-tails.md
git commit -m "docs: slice 9 implementation plan — scroll tails + coveyd tech debt"
```

---

## Definition of Done (from spec §6)

1. Build + full suite green (incl. new CoveyTerminalViewTests).
2. Wheel scrolls claude chat / `less` in TUI sessions; plain shell viewport unchanged.
3. Scrollbar drag to the bottom clears HISTORY.
4. Buffer switch (shell → vim) clears a stale HISTORY badge.
5. Killing a session whose child outlives the tty does not hang the daemon.
6. Auto names `s-N` are consecutive; oversize append keeps `since` gap-free.
