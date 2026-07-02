# coveyd Status Inference (Slice 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The daemon infers each session's status (running / waiting / idle) from a headless VT screen and reports it via a `statusChanged` event and statuses in the `list` response.

**Architecture:** Port of `amux-core/src/status.rs` as pure functions (`StatusInference`); a headless SwiftTerm `Terminal` per session (`ScreenModel`) fed from the PTY output chain; a 1.5 s `StatusMonitor` that diffs statuses and emits changes; `IPCServer` broadcasts `statusChanged` and enriches `list`. Spec: `docs/superpowers/specs/2026-07-01-coveyd-status-inference-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest, SwiftTerm ≥ 1.13.0 (https://github.com/migueldeicaza/SwiftTerm).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations (add/commit) are performed BY THE USER by hand; each task ends with the exact command to hand over.
- No `sleep` in tests — only `XCTestExpectation` / `wait(for:timeout:)` / the `waitUntil` polling helper.
- Closures dispatched onto queues/sources capture `self` via `[weak self]` (value captures like a `screen` reference are fine).
- TDD per memory `tdd-skeleton-first`: compilable skeleton → failing test → implementation.
- Test run pattern (hang-proof): `swift build --build-tests`, then
  `xcrun xctest -XCTest CoveydCoreTests.<ClassName> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`
  (dot-separated filter). Full suite: run the bundle without `-XCTest`.
- `Status` already exists in `Sources/CoveyKit/Models.swift` (`enum Status: String, Codable, Equatable { case running, waiting, idle }`) — do NOT redefine it.

---

### Task 1: StatusInference — pure port of `status.rs`

**Files:**
- Create: `Sources/CoveydCore/StatusInference.swift`
- Test: `Tests/CoveydCoreTests/StatusInferenceTests.swift`

**Interfaces:**
- Consumes: `CoveyKit.Status`.
- Produces (used by Task 5):
  - `StatusInference.parsePrompt(_ screen: String) -> [String]`
  - `StatusInference.contentHash(_ s: String) -> Int`
  - `StatusInference.isWorking(_ screen: String) -> Bool`
  - `StatusInference.computeStatus(prev: Int?, current: Int) -> Status`
  - `StatusInference.deriveStatus(content: String, prevHash: Int?, currentHash: Int, hasPrompt: Bool) -> Status`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/CoveydCore/StatusInference.swift`:

```swift
import CoveyKit

/// Pure agent-status inference, a port of amux-core's `status.rs`.
/// Input is the rendered visible-screen text (from `ScreenModel`), so unlike
/// the Rust original no ANSI stripping is needed. No IO.
public enum StatusInference {
    /// Substrings that mark an agent as actively working. Claude Code renders
    /// "esc to interrupt" while busy and drops it when idle.
    static let workingMarkers = ["esc to interrupt"]

    /// Detects a bottom-anchored numbered menu (Claude Code permission/choice
    /// prompt). Returns option labels for digits 1..N, or empty if no
    /// consecutive `1.` `2.` … run of at least two is found in the last 20 lines.
    public static func parsePrompt(_ screen: String) -> [String] {
        []
    }

    /// Hash of screen content for in-process change detection between ticks.
    /// Values are not stable across process restarts (like Rust's DefaultHasher).
    public static func contentHash(_ s: String) -> Int {
        0
    }

    /// Whether the screen shows an agent actively working.
    public static func isWorking(_ screen: String) -> Bool {
        false
    }

    /// First observation (no previous hash) is `.idle`; a changed hash → `.running`.
    public static func computeStatus(prev: Int?, current: Int) -> Status {
        .idle
    }

    /// Derive a session's status. Precedence: pending prompt → `.waiting`;
    /// working marker → `.running`; otherwise frame-diff via `computeStatus`.
    public static func deriveStatus(
        content: String, prevHash: Int?, currentHash: Int, hasPrompt: Bool
    ) -> Status {
        .idle
    }
}
```

- [ ] **Step 2: Write the failing tests** (port of all `status.rs` tests)

`Tests/CoveydCoreTests/StatusInferenceTests.swift`:

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class StatusInferenceTests: XCTestCase {
    func testParsePromptDetectsNumberedMenu() {
        let content = "some output\n  1. yes\n  2. no\n  3. cancel\n"
        XCTAssertEqual(StatusInference.parsePrompt(content), ["yes", "no", "cancel"])
    }

    func testParsePromptIgnoresSingleOption() {
        XCTAssertEqual(StatusInference.parsePrompt("1. only one\n"), [])
    }

    func testParsePromptHandlesSelectionMarkers() {
        let content = "❯ 1. accept\n  2. reject\n"
        XCTAssertEqual(StatusInference.parsePrompt(content), ["accept", "reject"])
    }

    func testParsePromptTruncatesLabelsTo40Chars() {
        let long = String(repeating: "x", count: 60)
        let content = "1. \(long)\n2. b\n"
        XCTAssertEqual(StatusInference.parsePrompt(content).first?.count, 40)
    }

    func testParsePromptIgnoresMenuAboveLast20Lines() {
        let menu = "1. yes\n2. no\n"
        let padding = String(repeating: "line\n", count: 25)
        XCTAssertEqual(StatusInference.parsePrompt(menu + padding), [])
    }

    func testContentHashStableForSameInput() {
        XCTAssertEqual(StatusInference.contentHash("abc"), StatusInference.contentHash("abc"))
        XCTAssertNotEqual(StatusInference.contentHash("abc"), StatusInference.contentHash("abd"))
    }

    func testComputeStatusFirstObservationIsIdle() {
        XCTAssertEqual(StatusInference.computeStatus(prev: nil, current: 5), .idle)
    }

    func testComputeStatusChangeIsRunning() {
        XCTAssertEqual(StatusInference.computeStatus(prev: 1, current: 2), .running)
        XCTAssertEqual(StatusInference.computeStatus(prev: 2, current: 2), .idle)
    }

    func testIsWorkingDetectsMarker() {
        XCTAssertTrue(StatusInference.isWorking("… esc to interrupt …"))
        XCTAssertFalse(StatusInference.isWorking("idle prompt >"))
    }

    func testDeriveStatusPrecedence() {
        // prompt wins over everything
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "esc to interrupt", prevHash: 1, currentHash: 2, hasPrompt: true),
            .waiting
        )
        // working marker beats frame-diff
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "esc to interrupt", prevHash: 2, currentHash: 2, hasPrompt: false),
            .running
        )
        // fallback to frame-diff
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "quiet", prevHash: 1, currentHash: 2, hasPrompt: false),
            .running
        )
        XCTAssertEqual(
            StatusInference.deriveStatus(content: "quiet", prevHash: 2, currentHash: 2, hasPrompt: false),
            .idle
        )
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.StatusInferenceTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -5
```

Expected: build OK, multiple failures (skeleton returns stubs).

- [ ] **Step 4: Implement**

Replace the stub bodies in `Sources/CoveydCore/StatusInference.swift`:

```swift
    public static func parsePrompt(_ screen: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        let start = max(0, lines.count - 20)
        var opts: [String] = []
        var expect = 1
        for line in lines[start...] {
            var t = Substring(line)
            while let f = t.first, f.isWhitespace || "❯>●·".contains(f) {
                t = t.dropFirst()
            }
            let prefix = "\(expect)."
            guard t.hasPrefix(prefix) else { continue }
            let label = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                opts.append(String(label.prefix(40)))
                expect += 1
            }
        }
        return opts.count >= 2 ? opts : []
    }

    public static func contentHash(_ s: String) -> Int {
        var h = Hasher()
        h.combine(s)
        return h.finalize()
    }

    public static func isWorking(_ screen: String) -> Bool {
        workingMarkers.contains { screen.contains($0) }
    }

    public static func computeStatus(prev: Int?, current: Int) -> Status {
        if let prev, prev != current { return .running }
        return .idle
    }

    public static func deriveStatus(
        content: String, prevHash: Int?, currentHash: Int, hasPrompt: Bool
    ) -> Status {
        if hasPrompt { return .waiting }
        if isWorking(content) { return .running }
        return computeStatus(prev: prevHash, current: currentHash)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/CoveydCore/StatusInference.swift Tests/CoveydCoreTests/StatusInferenceTests.swift
git commit -m "feat(coveydcore): pure status inference port (parsePrompt/contentHash/deriveStatus)"
```

---

### Task 2: Protocol — `statusChanged` event + statuses in `list`

**Files:**
- Modify: `Sources/CoveyKit/Protocol.swift` (Result.sessions, DaemonEvent)
- Modify: `Sources/CoveydCore/IPCServer.swift:64` (list reply — placeholder)
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`

**Interfaces:**
- Produces (used by Tasks 5–6):
  - `DaemonEvent.statusChanged(name: String, status: Status)`
  - `ServerMessage.Result.sessions(sessions: [Session], statuses: [String: Status])`
- Breaking wire change to `list` is deliberate: no clients exist besides tests.

- [ ] **Step 1: Write the failing tests**

In `Tests/CoveyKitTests/ProtocolTests.swift`, replace line 36 (`.response(id: 3, result: .sessions([s])),`) with:

```swift
            .response(id: 3, result: .sessions(sessions: [s], statuses: ["s-1": .running])),
```

add `.event(.statusChanged(name: "s-1", status: .waiting)),` after the `.sessionRemoved` line in the same array, and add a golden wire-format test at the end of the class:

```swift
    func testStatusChangedGoldenWireFormat() throws {
        let data = try encoder().encode(DaemonEvent.statusChanged(name: "s-1", status: .waiting))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"statusChanged":{"name":"s-1","status":"waiting"}}"#
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

```bash
swift build --build-tests 2>&1 | tail -5
```

Expected: compile errors (`statusChanged` and the new `sessions` shape don't exist).

- [ ] **Step 3: Implement the protocol change**

In `Sources/CoveyKit/Protocol.swift`:

```swift
        case sessions([Session])
```
→
```swift
        case sessions(sessions: [Session], statuses: [String: Status])
```

and in `DaemonEvent` add after `case exited(...)`:

```swift
    case statusChanged(name: String, status: Status)
```

In `Sources/CoveydCore/IPCServer.swift` line 64, keep it compiling with an empty placeholder (finalized in Task 6):

```swift
        case .list:
            reply(.sessions(sessions: registry.list(), statuses: [:]))
```

- [ ] **Step 4: Run the full suite to verify everything passes**

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -3
```

Expected: all tests pass (37 + Task 1's 10 + the new ones).

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveyKit/Protocol.swift Sources/CoveydCore/IPCServer.swift Tests/CoveyKitTests/ProtocolTests.swift
git commit -m "feat(coveykit): statusChanged event + statuses map in list result"
```

---

### Task 3: SwiftTerm dependency + ScreenModel

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CoveydCore/ScreenModel.swift`
- Test: `Tests/CoveydCoreTests/ScreenModelTests.swift`

**Interfaces:**
- Produces (used by Task 4):
  - `ScreenModel(cols: Int = 80, rows: Int = 24)`
  - `func feed(_ bytes: [UInt8])`
  - `func resize(cols: Int, rows: Int)`
  - `func visibleText() -> String` — text of the ACTIVE buffer (incl. alternate screen), rows joined with `\n`, trailing blanks trimmed per line.
- All three methods are internally lock-guarded: `feed` runs on the PTY queue, `resize` on the IPC queue, `visibleText` on the monitor queue.

- [ ] **Step 1: Add the SwiftTerm dependency**

In `Package.swift`, add to the `Package` init after `platforms:`:

```swift
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
    ],
```

and change the `CoveydCore` target:

```swift
        .target(
            name: "CoveydCore",
            dependencies: [
                "CoveyKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

Run `swift build 2>&1 | tail -2`. Expected: dependency resolves, `Build complete!`.

- [ ] **Step 2: Write the compilable skeleton**

`Sources/CoveydCore/ScreenModel.swift`:

```swift
import Foundation
import SwiftTerm

/// Headless VT screen of one session: parses the raw PTY byte stream and
/// exposes the text a user would currently see (active buffer, including the
/// alternate screen Claude Code runs in). This is the coveyd analog of
/// `tmux capture-pane` that Rust's status inference relied on.
///
/// Thread-safety: `feed` (PTY queue), `resize` (IPC queue) and `visibleText`
/// (status-monitor queue) are all serialized on an internal lock.
public final class ScreenModel: TerminalDelegate {
    private let lock = NSLock()
    private var terminal: Terminal!

    public init(cols: Int = 80, rows: Int = 24) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
    }

    public func feed(_ bytes: [UInt8]) {
    }

    public func resize(cols: Int, rows: Int) {
    }

    /// Rows of the active buffer, right-trimmed, joined with "\n".
    public func visibleText() -> String {
        ""
    }

    // MARK: - TerminalDelegate (the daemon never answers back to the app)
    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/CoveydCoreTests/ScreenModelTests.swift`:

```swift
import XCTest
@testable import CoveydCore

final class ScreenModelTests: XCTestCase {
    func testPlainTextAppearsOnScreen() {
        let screen = ScreenModel()
        screen.feed(bytes("hello\r\nworld"))
        let text = screen.visibleText()
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("world"))
    }

    // The case that broke a naive raw-scrollback port: after a redraw the
    // working marker must disappear from the visible screen.
    func testRedrawDropsStaleWorkingMarker() {
        let screen = ScreenModel()
        screen.feed(bytes("Thinking… esc to interrupt"))
        XCTAssertTrue(screen.visibleText().contains("esc to interrupt"))
        screen.feed(bytes("\u{1b}[2J\u{1b}[Hdone"))   // clear screen + home + new frame
        let text = screen.visibleText()
        XCTAssertTrue(text.contains("done"))
        XCTAssertFalse(text.contains("esc to interrupt"))
    }

    func testAlternateScreenIsTheVisibleOne() {
        let screen = ScreenModel()
        screen.feed(bytes("primary"))
        screen.feed(bytes("\u{1b}[?1049h"))            // switch to alt screen
        screen.feed(bytes("alt-content"))
        XCTAssertTrue(screen.visibleText().contains("alt-content"))
        XCTAssertFalse(screen.visibleText().contains("primary"))
    }

    func testResizeChangesRowCount() {
        let screen = ScreenModel(cols: 80, rows: 24)
        screen.resize(cols: 100, rows: 30)
        XCTAssertEqual(screen.visibleText().components(separatedBy: "\n").count, 30)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.ScreenModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -5
```

Expected: 4 failures (stubs return empty).

- [ ] **Step 5: Implement**

Replace the stub bodies:

```swift
    public func feed(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        terminal.feed(byteArray: bytes)
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        terminal.resize(cols: cols, rows: rows)
    }

    public func visibleText() -> String {
        lock.lock(); defer { lock.unlock() }
        return (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }
```

API notes (verified against SwiftTerm main): the only `TerminalDelegate`
requirement without a default implementation is `send(source:data:)`;
`getLine(row:)` indexes the visible display of the active buffer
(`buffer.lines[row + buffer.yDisp]`), so alt-screen handling is automatic.

- [ ] **Step 6: Run tests to verify they pass**

Same command as Step 4. Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 7: Hand off commit to the user**

```bash
git add Package.swift Package.resolved Sources/CoveydCore/ScreenModel.swift Tests/CoveydCoreTests/ScreenModelTests.swift
git commit -m "feat(coveydcore): headless SwiftTerm screen model per session"
```

---

### Task 4: SessionRegistry — feed the screen, expose snapshots

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift`
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`
- Modify: `Tests/CoveydCoreTests/TestSupport.swift`, `Tests/CoveydCoreTests/IPCServerTests.swift` (move `waitUntil` helper — closes part of deferred finding #9)

**Interfaces:**
- Consumes: `ScreenModel` from Task 3.
- Produces (used by Tasks 5–6):
  - `SessionRegistry.snapshotScreens() -> [String: String]` (name → visible text)
- Behavior changes:
  - every session owns a `ScreenModel` (80×24, resized on `resize`) fed from PTY output even when no client is attached;
  - `attachOutput(name:_:)` keeps its signature; the installed handler now feeds the screen first, then forwards to the client handler (screen is captured by reference, so feeding survives `rename`).

- [ ] **Step 1: Move `waitUntil` into TestSupport**

Append to `Tests/CoveydCoreTests/TestSupport.swift`:

```swift
extension XCTestCase {
    /// Polls `cond` every 20 ms until true, failing the test after 5 s.
    func waitUntil(_ cond: @escaping () -> Bool, _ desc: String) {
        let exp = expectation(description: desc)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { if cond() { timer.cancel(); exp.fulfill() } }
        timer.resume()
        wait(for: [exp], timeout: 5)
    }
}
```

Delete the identical `private func waitUntil` from `Tests/CoveydCoreTests/IPCServerTests.swift` (lines 15–22). Run the full suite — still green:

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -3
```

- [ ] **Step 2: Write the failing test**

Append to `Tests/CoveydCoreTests/SessionRegistryTests.swift` (inside the class):

```swift
    func testSnapshotScreensShowsSessionOutput() throws {
        let reg = SessionRegistry()
        _ = try reg.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'hello-screen'; exec cat"],
            name: "scr"
        )
        waitUntil({ reg.snapshotScreens()["scr"]?.contains("hello-screen") == true },
                  "screen shows output")
        reg.kill(name: "scr")
    }
```

- [ ] **Step 3: Run test to verify it fails to compile**

```bash
swift build --build-tests 2>&1 | tail -5
```

Expected: error — `snapshotScreens` does not exist.

- [ ] **Step 4: Implement**

In `Sources/CoveydCore/SessionRegistry.swift`:

1. Extend the entry tuple (line 16):

```swift
    private var entries: [String: (session: Session, process: PTYProcess, screen: ScreenModel)] = [:]
```

2. In `create`, build the screen and install the default feed-only handler.
After `let proc = PTYProcess()` add:

```swift
        let screen = ScreenModel(cols: 80, rows: 24)
        proc.setOutputHandler { bytes, _ in screen.feed(bytes) }
```

and change the entry insert to:

```swift
        entries[id] = (session, proc, screen)
```

3. Replace `attachOutput` so the client handler is layered on top of the feed
(handler assignment is serialized on the PTY queue by `setOutputHandler`):

```swift
    public func attachOutput(
        name: String,
        _ handler: @escaping ([UInt8], Int) -> Void
    ) {
        lock.lock()
        guard let entry = entries[name] else { lock.unlock(); return }
        let proc = entry.process
        let screen = entry.screen
        lock.unlock()
        proc.setOutputHandler { bytes, seq in
            screen.feed(bytes)
            handler(bytes, seq)
        }
    }
```

4. In `resize`, also resize the screen:

```swift
    public func resize(name: String, cols: UInt16, rows: UInt16) {
        lock.lock()
        let proc = entries[name]?.process
        let screen = entries[name]?.screen
        lock.unlock()
        proc?.resize(cols: cols, rows: rows)
        screen?.resize(cols: Int(cols), rows: Int(rows))
    }
```

5. Add the snapshot accessor:

```swift
    /// Visible screen text of every live session, for status inference.
    public func snapshotScreens() -> [String: String] {
        lock.lock()
        let screens = entries.mapValues(\.screen)
        lock.unlock()
        return screens.mapValues { $0.visibleText() }
    }
```

- [ ] **Step 5: Run the full suite to verify it passes**

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -3
```

Expected: 0 failures (existing registry/IPC/e2e tests confirm the fan-out chain still works).

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift Tests/CoveydCoreTests/TestSupport.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(coveydcore): per-session screen model fed from PTY output"
```

---

### Task 5: StatusMonitor

**Files:**
- Create: `Sources/CoveydCore/StatusMonitor.swift`
- Test: `Tests/CoveydCoreTests/StatusMonitorTests.swift`

**Interfaces:**
- Consumes: `StatusInference` (Task 1). The screen source is an injected
  closure — `SessionRegistry.snapshotScreens` in production (wired in Task 6),
  a plain dictionary in tests.
- Produces (used by Task 6):
  - `StatusMonitor(interval: TimeInterval = 1.5, snapshot: @escaping () -> [String: String])`
  - `var onStatusChanged: ((String, Status) -> Void)?` — fires on the monitor queue, only when a session's status differs from the previous tick (the first tick always fires: unknown → known)
  - `func tick()` — one synchronous inference pass (what the timer calls; tests call it directly)
  - `func start()` / `func stop()` — the 1.5 s repeating timer
  - `func currentStatuses() -> [String: Status]` — statuses as of the last tick; sessions gone from the snapshot are pruned

- [ ] **Step 1: Write the compilable skeleton**

`Sources/CoveydCore/StatusMonitor.swift`:

```swift
import Foundation
import CoveyKit

/// Periodically derives every session's status from its visible screen and
/// reports transitions. Mirrors the 1.5 s poller of the Rust desktop app,
/// but lives in the daemon. All state is confined to the serial `queue`.
public final class StatusMonitor {
    /// Fires only when a session's status differs from the previous tick.
    public var onStatusChanged: ((String, Status) -> Void)?

    private let snapshot: () -> [String: String]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.status")
    private var timer: DispatchSourceTimer?
    private var prevHash: [String: Int] = [:]
    private var prevStatus: [String: Status] = [:]

    public init(
        interval: TimeInterval = 1.5,
        snapshot: @escaping () -> [String: String]
    ) {
        self.interval = interval
        self.snapshot = snapshot
    }

    public func start() {
    }

    public func stop() {
    }

    /// One inference pass. The timer calls this; tests call it directly.
    public func tick() {
    }

    public func currentStatuses() -> [String: Status] {
        [:]
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveydCoreTests/StatusMonitorTests.swift`:

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class StatusMonitorTests: XCTestCase {
    // Events are appended from the monitor queue while the test thread is
    // blocked in the synchronous tick(), so plain array access is safe.
    private func makeMonitor(_ screens: @escaping () -> [String: String])
        -> (StatusMonitor, () -> [(String, Status)]) {
        let monitor = StatusMonitor(snapshot: screens)
        let lock = NSLock()
        var events: [(String, Status)] = []
        monitor.onStatusChanged = { name, st in
            lock.lock(); events.append((name, st)); lock.unlock()
        }
        return (monitor, { lock.lock(); defer { lock.unlock() }; return events })
    }

    func testFirstTickEmitsInitialStatusThenStaysQuiet() {
        var screens = ["s": "hello"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().map(\.1), [.idle])   // first observation
        m.tick()                                      // unchanged content
        XCTAssertEqual(events().count, 1)             // no spam
        screens["s"] = "hello world"
        m.tick()
        XCTAssertEqual(events().last?.1, .running)    // frame changed
    }

    func testPromptYieldsWaiting() {
        let screens = ["s": "pick one:\n  1. yes\n  2. no"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().last?.1, .waiting)
        XCTAssertEqual(m.currentStatuses(), ["s": .waiting])
    }

    func testWorkingMarkerYieldsRunningEvenOnFirstTick() {
        let screens = ["s": "Thinking… esc to interrupt"]
        let (m, events) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(events().last?.1, .running)
    }

    func testRemovedSessionIsPruned() {
        var screens = ["s": "hello"]
        let (m, _) = makeMonitor { screens }
        m.tick()
        XCTAssertEqual(m.currentStatuses(), ["s": .idle])
        screens = [:]
        m.tick()
        XCTAssertEqual(m.currentStatuses(), [:])
    }

    func testTimerTicksWithoutManualTick() {
        let screens = ["s": "pick:\n  1. a\n  2. b"]
        let m = StatusMonitor(interval: 0.05, snapshot: { screens })
        let exp = expectation(description: "timer tick emits waiting")
        m.onStatusChanged = { _, st in if st == .waiting { exp.fulfill() } }
        m.start()
        wait(for: [exp], timeout: 5)
        m.stop()
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.StatusMonitorTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -5
```

Expected: 5 failures (stubs do nothing; the timer test fails by timeout after 5 s — expected, only on this red run).

- [ ] **Step 4: Implement**

Replace the stub bodies in `Sources/CoveydCore/StatusMonitor.swift`:

```swift
    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func tick() {
        queue.sync { tickBody() }
    }

    public func currentStatuses() -> [String: Status] {
        queue.sync { prevStatus }
    }

    // MARK: - private (on `queue`)

    private func tickBody() {
        let screens = snapshot()
        var newHash: [String: Int] = [:]
        var newStatus: [String: Status] = [:]
        for (name, content) in screens {
            let hash = StatusInference.contentHash(content)
            let prompt = StatusInference.parsePrompt(content)
            let status = StatusInference.deriveStatus(
                content: content,
                prevHash: prevHash[name],
                currentHash: hash,
                hasPrompt: !prompt.isEmpty
            )
            newHash[name] = hash
            newStatus[name] = status
            if prevStatus[name] != status {
                onStatusChanged?(name, status)
            }
        }
        // Replacing the maps wholesale prunes removed sessions.
        prevHash = newHash
        prevStatus = newStatus
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 5 tests, with 0 failures` (fast — the timer test uses a 50 ms interval).

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/CoveydCore/StatusMonitor.swift Tests/CoveydCoreTests/StatusMonitorTests.swift
git commit -m "feat(coveydcore): status monitor with change-only events"
```

---

### Task 6: Wire it all — IPCServer, main.swift, end-to-end

**Files:**
- Modify: `Sources/CoveydCore/IPCServer.swift` (init signature, list, broadcast)
- Modify: `Sources/coveyd/main.swift:35-36`
- Modify: `Tests/CoveydCoreTests/IPCServerTests.swift` (constructor call sites + new test)
- Modify: `Tests/CoveydCoreTests/EndToEndTests.swift:9` (constructor call site)

**Interfaces:**
- Consumes: `StatusMonitor` (Task 5), `snapshotScreens` (Task 4), protocol (Task 2).
- Produces: `IPCServer(registry: SessionRegistry, monitor: StatusMonitor)` — BREAKING init change; `list` replies real statuses (`.idle` for sessions never ticked); `statusChanged` broadcast to every connected client.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CoveydCoreTests/IPCServerTests.swift` (inside the class):

```swift
    func testTickBroadcastsWaitingAndListCarriesStatuses() {
        let registry = SessionRegistry()
        let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        let server = IPCServer(registry: registry, monitor: monitor)
        let sink = FakeSink(id: 1)
        server.register(sink)
        // A session whose screen ends in a numbered menu -> waiting.
        server.handle(Request(id: 1, op: .create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")), from: sink)
        waitUntil({ registry.snapshotScreens()["menu"]?.contains("2. no") == true },
                  "menu rendered")
        monitor.tick()
        waitUntil({ sink.captured.contains {
            if case .event(.statusChanged("menu", .waiting)) = $0 { return true }
            return false
        } }, "statusChanged waiting")
        server.handle(Request(id: 2, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .sessions(_, let statuses)) = $0 {
                return statuses["menu"] == .waiting
            }
            return false
        } }, "list has statuses")
        server.handle(Request(id: 3, op: .kill(name: "menu")), from: sink)
    }
```

- [ ] **Step 2: Run to verify it fails to compile**

```bash
swift build --build-tests 2>&1 | tail -5
```

Expected: error — `IPCServer` has no `monitor:` parameter.

- [ ] **Step 3: Implement**

In `Sources/CoveydCore/IPCServer.swift`:

1. Add the stored monitor and extend init:

```swift
    private let registry: SessionRegistry
    private let monitor: StatusMonitor
```

```swift
    public init(registry: SessionRegistry, monitor: StatusMonitor) {
        self.registry = registry
        self.monitor = monitor
        registry.onSessionAdded = { [weak self] s in
            self?.broadcast(.event(.sessionAdded(session: s)))
        }
        registry.onSessionRemoved = { [weak self] name in
            self?.broadcast(.event(.sessionRemoved(name: name)))
        }
        registry.onExit = { [weak self] name, code in
            guard let self else { return }
            self.broadcast(.event(.exited(name: name, code: code)))
            self.server.async { self.subscribers[name] = nil }
        }
        monitor.onStatusChanged = { [weak self] name, status in
            self?.broadcast(.event(.statusChanged(name: name, status: status)))
        }
    }
```

(The three registry closures are the existing wiring, unchanged — only the
`monitor` property, the init parameter, and the last closure are new.)

2. Replace the Task 2 placeholder in `dispatch`:

```swift
        case .list:
            let sessions = registry.list()
            let known = monitor.currentStatuses()
            var statuses: [String: Status] = [:]
            for s in sessions { statuses[s.name] = known[s.name] ?? .idle }
            reply(.sessions(sessions: sessions, statuses: statuses))
```

3. Update the three remaining `IPCServer(registry:)` call sites:

`Tests/CoveydCoreTests/IPCServerTests.swift` — the two existing tests that
construct inline (`testCreateReturnsSessionAndBroadcastsAdded`,
`testUnknownNameReturnsNotFound`, `testAttachStreamsBackfillAndLiveOutput`) each become:

```swift
        let registry = SessionRegistry()   // keep `clock: { 1 }` where present
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
```

`Tests/CoveydCoreTests/EndToEndTests.swift:9`:

```swift
        let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        let ipc = IPCServer(registry: registry, monitor: monitor)
```

`Sources/coveyd/main.swift:35-36`:

```swift
let registry = SessionRegistry()
let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
let ipc = IPCServer(registry: registry, monitor: monitor)
```

and start the timer right after the `try server.start()` success line (before `dispatchMain()`):

```swift
monitor.start()
```

- [ ] **Step 4: Run the full suite**

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -3
```

Expected: 0 failures (~57 tests).

- [ ] **Step 5: Smoke-test the real daemon (Definition of Done §9.2 of the spec)**

```bash
swift build 2>&1 | tail -1
.build/debug/coveyd &
printf '{"id":1,"op":{"create":{"dir":"/tmp","agent":"sh","argv":["/bin/sh","-c","printf '\''pick:\\n  1. yes\\n  2. no\\n'\''; exec cat"],"name":"m"}}}\n{"id":2,"op":{"list":{}}}\n' | nc -U ~/.covey/coveyd.sock & sleep 4; kill %2 2>/dev/null
# expect on the nc output: a statusChanged event {"name":"m","status":"waiting"}
# and, if list arrived after the first tick, statuses in the list response
kill %1
```

(`sleep` here is a shell smoke-test, not an XCTest — allowed.) Verify:
`statusChanged … waiting` appears within ~2 s (first 1.5 s tick), the daemon
exits cleanly and removes the socket.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/CoveydCore/IPCServer.swift Sources/coveyd/main.swift Tests/CoveydCoreTests/IPCServerTests.swift Tests/CoveydCoreTests/EndToEndTests.swift
git commit -m "feat(coveyd): broadcast statusChanged + statuses in list"
```

---

## Definition of Done (from spec §9)

1. `swift build` + full suite green (old 37 + ~20 new).
2. Live daemon: menu session → client receives `statusChanged: waiting`; `list` carries statuses.
3. Events fire only on change (StatusMonitorTests cover the no-spam case).
4. Inference precedence byte-for-byte matches `status.rs` (StatusInferenceTests port all upstream tests).
