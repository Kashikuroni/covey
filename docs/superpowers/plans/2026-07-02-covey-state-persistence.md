# covey State Persistence (Slice 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist UI state to `~/.covey/state.json` — theme, split width, and a Recent tab of stopped sessions — surviving app restarts.

**Architecture:** A pure Codable `PersistedState` (CoveyKit) + a `StateStore` (covey) that loads/saves JSON with a debounced, atomic write. `AppModel` loads state on start, persists on change, and pushes a `RecentSession` on each `.exited` event. Views gain an Active/Recent picker, a theme toggle, and a draggable divider bound to the saved split width. Spec: `docs/superpowers/specs/2026-07-02-covey-state-persistence-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, built-in `JSONEncoder`/`JSONDecoder` (no new dependencies), XCTest.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No new external dependencies — JSON via the standard library, not TOML.
- No thread `sleep` in tests; use `StateStore.flush()` or short debounce + async polling.
- Closures on queues capture `self` via `[weak self]`.
- TDD for `PersistedState`, `StateStore`, `AppModel` (skeleton → failing test → impl); views are compile-checked and verified by the Task 4 manual smoke.
- Full schema lives in `PersistedState`; only `theme`, `splitPct`, `recents` get UI this slice. Other fields round-trip untouched.
- Ownership: Active = daemon `list`; Recent = `state.json`. Recents come from `.exited`, NOT `.sessionRemoved` (rename).
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Module>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`. Full suite: bundle without `-XCTest`.

---

### Task 1: PersistedState in CoveyKit

**Files:**
- Create: `Sources/CoveyKit/PersistedState.swift`
- Test: `Tests/CoveyKitTests/PersistedStateTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–3):
  - `struct PersistedSession: Codable, Equatable { var dir, agent: String; var resumeCmd: String? }`
  - `struct RecentSession: Codable, Equatable { var name, dir, agent: String; var resumeCmd: String? }`
  - `struct PersistedState: Codable, Equatable` — full schema, `init()` all-empty
  - `let maxRecents = 20`
  - `func pushRecent(_ recents: inout [RecentSession], _ entry: RecentSession)`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/CoveyKit/PersistedState.swift`:

```swift
import Foundation

/// Enough to recreate a session after a restart. `resumeCmd` is the Claude Code
/// `--resume <uuid>` command from a clean shutdown; nil for fresh/non-Claude.
public struct PersistedSession: Codable, Equatable {
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
    public init(dir: String, agent: String, resumeCmd: String? = nil) {
        self.dir = dir; self.agent = agent; self.resumeCmd = resumeCmd
    }
}

/// A recently-stopped session, kept so it can be re-launched from the Recent tab.
public struct RecentSession: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var resumeCmd: String?
    public init(name: String, dir: String, agent: String, resumeCmd: String? = nil) {
        self.name = name; self.dir = dir; self.agent = agent; self.resumeCmd = resumeCmd
    }
}

public let maxRecents = 20

/// Move `entry` to the front of `recents`: drop any existing entry with the same
/// name (so a re-stopped session moves up without duplicating), then truncate to
/// `maxRecents`. Port of amux-core `push_recent`.
public func pushRecent(_ recents: inout [RecentSession], _ entry: RecentSession) {
    recents.removeAll { $0.name == entry.name }
    recents.insert(entry, at: 0)
    if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
}

/// Persisted UI state (`~/.covey/state.json`). Owned by the GUI. Optional scalars
/// are omitted from JSON when nil (Swift synthesizes `encodeIfPresent`); empty
/// collections round-trip as `[]`/`{}`.
public struct PersistedState: Codable, Equatable {
    // wired this slice
    public var theme: String?
    public var splitPct: Int?
    public var recents: [RecentSession]
    // schema-only (round-trip, no UI this slice)
    public var order: [String]
    public var projectOrder: [String]
    public var projectNames: [String: String]
    public var projectNotes: [String: String]
    public var notes: [String: String]
    public var drafts: [String: String]
    public var sessions: [String: PersistedSession]
    public var fontScale: Int?
    public var sbWidth: Int?
    public var showSessions: Bool?
    public var showFooter: Bool?
    public var showHeader: Bool?
    public var lastVersion: String?

    public init(
        theme: String? = nil, splitPct: Int? = nil, recents: [RecentSession] = [],
        order: [String] = [], projectOrder: [String] = [],
        projectNames: [String: String] = [:], projectNotes: [String: String] = [:],
        notes: [String: String] = [:], drafts: [String: String] = [:],
        sessions: [String: PersistedSession] = [:],
        fontScale: Int? = nil, sbWidth: Int? = nil,
        showSessions: Bool? = nil, showFooter: Bool? = nil, showHeader: Bool? = nil,
        lastVersion: String? = nil
    ) {
        self.theme = theme; self.splitPct = splitPct; self.recents = recents
        self.order = order; self.projectOrder = projectOrder
        self.projectNames = projectNames; self.projectNotes = projectNotes
        self.notes = notes; self.drafts = drafts; self.sessions = sessions
        self.fontScale = fontScale; self.sbWidth = sbWidth
        self.showSessions = showSessions; self.showFooter = showFooter
        self.showHeader = showHeader; self.lastVersion = lastVersion
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyKitTests/PersistedStateTests.swift`:

```swift
import XCTest
@testable import CoveyKit

final class PersistedStateTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        var s = PersistedState(theme: "light", splitPct: 42)
        s.recents = [RecentSession(name: "a", dir: "/w", agent: "claude", resumeCmd: "claude --resume x")]
        s.order = ["a", "b"]
        s.projectNames = ["/w": "Work"]
        s.notes = ["a": "- [ ] task"]
        s.sessions = ["a": PersistedSession(dir: "/w", agent: "claude")]
        s.showSessions = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testNilScalarsAreOmitted() throws {
        let data = try JSONEncoder().encode(PersistedState())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("theme"))      // nil -> omitted
        XCTAssertFalse(json.contains("splitPct"))
        XCTAssertTrue(json.contains("recents"))     // empty array -> present
    }

    func testPushRecentDedupesNewestFirst() {
        var r: [RecentSession] = []
        pushRecent(&r, RecentSession(name: "a", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "b", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "a", dir: "/w2", agent: "sh"))  // re-stop a
        XCTAssertEqual(r.map(\.name), ["a", "b"])   // a moved to front, no dup
        XCTAssertEqual(r.first?.dir, "/w2")          // newest payload wins
    }

    func testPushRecentTruncatesToMax() {
        var r: [RecentSession] = []
        for i in 0..<(maxRecents + 5) {
            pushRecent(&r, RecentSession(name: "s\(i)", dir: "/w", agent: "sh"))
        }
        XCTAssertEqual(r.count, maxRecents)
        XCTAssertEqual(r.first?.name, "s\(maxRecents + 4)")  // last pushed is first
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyKitTests.PersistedStateTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: build OK; if the skeleton already returns correct values these may pass —
that is acceptable for a pure-data type (the skeleton IS the implementation). If any
fail, fix inline. The point of Step 3 is to confirm the tests run and exercise the type.

- [ ] **Step 4: Run the full suite**

```bash
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: 79 + 4 = 83 tests, 0 failures, 1 skipped.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveyKit/PersistedState.swift Tests/CoveyKitTests/PersistedStateTests.swift
git commit -m "feat(coveykit): persisted state model + recents"
```

---

### Task 2: StateStore

**Files:**
- Create: `Sources/covey/StateStore.swift`
- Test: `Tests/CoveyAppTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: `PersistedState` (Task 1).
- Produces (used by Task 3):
  - `StateStore(path: String, debounce: TimeInterval = 0.5)`
  - `func load() -> PersistedState`
  - `func save(_ state: PersistedState)` — debounced, coalescing
  - `func flush()` — write any pending state synchronously
  - `var writeCount: Int` — number of actual disk writes (test seam)

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/StateStore.swift`:

```swift
import Foundation
import CoveyKit

/// Loads/saves `PersistedState` as JSON. Saves are debounced (repeated calls
/// coalesce into one write of the latest value) and atomic (`Data.write(.atomic)`
/// writes to a temp file then renames, so no partial file is ever observable).
public final class StateStore {
    private let url: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "covey.state")
    private var timer: DispatchSourceTimer?
    private var pending: PersistedState?
    private var _writeCount = 0

    public init(path: String, debounce: TimeInterval = 0.5) {
        self.url = URL(fileURLWithPath: path)
        self.debounce = debounce
    }

    public func load() -> PersistedState {
        PersistedState()
    }

    public func save(_ state: PersistedState) {
    }

    public func flush() {
    }

    public var writeCount: Int {
        queue.sync { _writeCount }
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/StateStoreTests.swift`:

```swift
import XCTest
@testable import covey
import CoveyKit

final class StateStoreTests: XCTestCase {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())covey-state-\(UInt32.random(in: 0..<UInt32.max)).json"
    }

    func testSaveFlushLoadRoundTrips() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)
        var s = PersistedState(theme: "light", splitPct: 30)
        s.recents = [RecentSession(name: "a", dir: "/w", agent: "sh")]
        store.save(s)
        store.flush()
        let back = StateStore(path: path).load()
        XCTAssertEqual(back.theme, "light")
        XCTAssertEqual(back.splitPct, 30)
        XCTAssertEqual(back.recents.map(\.name), ["a"])
    }

    func testDebounceCoalescesManySavesIntoOneWrite() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)   // long: nothing fires on its own
        for i in 0..<10 { store.save(PersistedState(splitPct: i)) }
        store.flush()
        XCTAssertEqual(store.writeCount, 1, "10 saves + flush must be a single write")
        XCTAssertEqual(StateStore(path: path).load().splitPct, 9)  // last value won
    }

    func testMissingFileLoadsDefault() {
        let store = StateStore(path: tempPath())   // never written
        XCTAssertEqual(store.load(), PersistedState())
    }

    func testCorruptFileLoadsDefault() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(StateStore(path: path).load(), PersistedState())
    }

    func testNoTempFileLeftBehind() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)
        store.save(PersistedState(theme: "dark"))
        store.flush()
        // .atomic writes to a sibling temp then renames; nothing but the final file remains.
        let dir = (path as NSString).deletingLastPathComponent
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let base = (path as NSString).lastPathComponent
        XCTAssertFalse(leftovers.contains { $0 != base && $0.contains(base) })
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.StateStoreTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 5 tests, ≥4 failures (stubs no-op; missing-file test may pass).

- [ ] **Step 4: Implement**

Replace the stub bodies in `Sources/covey/StateStore.swift`:

```swift
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    public func save(_ state: PersistedState) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = state
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.debounce)
            t.setEventHandler { [weak self] in self?.writePending() }
            self.timer = t
            t.resume()
        }
    }

    public func flush() {
        queue.sync {
            timer?.cancel()
            timer = nil
            writePending()
        }
    }

    // MARK: - private (on `queue`)

    private func writePending() {
        timer = nil
        guard let state = pending else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)   // temp + rename under the hood
            _writeCount += 1
        } catch {
            // best-effort persistence; a failed write must not crash the UI
        }
    }
```

Note: `flush()` uses `queue.sync` and `writePending` runs on the queue — no
re-entrancy (flush cancels the timer first). `writeCount`'s `queue.sync` getter is
safe because `writePending` never calls it.

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/StateStore.swift Tests/CoveyAppTests/StateStoreTests.swift
git commit -m "feat(covey): debounced atomic JSON state store"
```

---

### Task 3: AppModel — load, persist, recents, relaunch

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/covey/App.swift` (construct the real StateStore)
- Modify: `Tests/CoveyAppTests/AppTestSupport.swift` (makeModel injects a temp store)
- Test: `Tests/CoveyAppTests/AppModelTests.swift` (append)

**Interfaces:**
- Consumes: `StateStore` (Task 2), `PersistedState`/`RecentSession`/`pushRecent` (Task 1).
- Produces (used by Task 4):
  - `AppModel(client: IPCClient, makeClient: @escaping () throws -> IPCClient, store: StateStore)`
  - `var theme: Theme` (see Task 4 for the enum; here store the raw string), exposed as `public private(set) var themeRaw: String` + `setTheme(_ raw: String)`
  - `public private(set) var splitPct: Int` + `setSplitPct(_ pct: Int)`
  - `public private(set) var recents: [RecentSession]`
  - `func relaunchRecent(_ r: RecentSession) async`

  To avoid a forward dependency on Task 4's `Theme` enum, AppModel stores the theme
  as a `String` ("dark"/"light"); Task 4's views map it to the enum.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CoveyAppTests/AppModelTests.swift` (inside the class):

```swift
    @MainActor
    func testExitedPushesRecentWithDirAndAgent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.kill(name)                        // -> .exited
        let recorded = await eventually { model.recents.contains { $0.name == name } }
        XCTAssertTrue(recorded)
        let r = model.recents.first { $0.name == name }
        XCTAssertEqual(r?.dir, "/usr")
        XCTAssertEqual(r?.agent, "/bin/cat")
    }

    @MainActor
    func testRenameDoesNotPushRecent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.rename(name, to: "renamed")       // -> sessionRemoved + sessionAdded
        _ = await eventually { model.sessions.contains { $0.name == "renamed" } }
        XCTAssertFalse(model.recents.contains { $0.name == name },
                       "rename must not create a recent")
        await model.kill("renamed")
    }

    @MainActor
    func testRelaunchRecentCreatesSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let r = RecentSession(name: "back", dir: "/usr", agent: "/bin/cat")
        await model.relaunchRecent(r)
        let alive = await eventually { model.sessions.contains { $0.name == "back" } }
        XCTAssertTrue(alive)
        await model.kill("back")
    }

    @MainActor
    func testSetThemeAndSplitPersistToStore() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-appstate-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setTheme("light")
        model.setSplitPct(25)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.theme, "light")
        XCTAssertEqual(reloaded.splitPct, 25)
    }

    @MainActor
    func testStartAppliesPersistedThemeSplitRecents() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-appstate-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Pre-seed a state file.
        var seed = PersistedState(theme: "light", splitPct: 33)
        seed.recents = [RecentSession(name: "old", dir: "/w", agent: "sh")]
        let store0 = StateStore(path: path, debounce: 0.01)
        store0.save(seed); store0.flush()

        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertEqual(model.themeRaw, "light")
        XCTAssertEqual(model.splitPct, 33)
        XCTAssertEqual(model.recents.map(\.name), ["old"])
    }
```

- [ ] **Step 2: Update the test harness for the new init**

In `Tests/CoveyAppTests/AppTestSupport.swift`, change `makeModel` to inject a temp store:

```swift
    @MainActor
    func makeModel(_ daemon: TestDaemon) throws -> (AppModel, IPCClient) {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        let path = daemon.path
        let statePath = "\(NSTemporaryDirectory())covey-model-\(UInt32.random(in: 0..<UInt32.max)).json"
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05))
        return (model, client)
    }
```

- [ ] **Step 3: Run tests to verify they fail to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

Expected: errors — `AppModel` has no `store:` parameter, no `themeRaw`/`splitPct`/
`recents`/`setTheme`/`setSplitPct`/`relaunchRecent`.

- [ ] **Step 4: Implement**

In `Sources/covey/AppModel.swift`:

1. Add stored state + store, after `connected`:

```swift
    public private(set) var themeRaw: String = "dark"
    public private(set) var splitPct: Int = 38
    public private(set) var recents: [RecentSession] = []
```

2. Add the store + a cache of schema-only fields, near `private var client`:

```swift
    private let store: StateStore
    private var persisted = PersistedState()   // last known full state (keeps schema-only fields)
```

3. Replace the initializer:

```swift
    public init(client: IPCClient,
                makeClient: @escaping () throws -> IPCClient,
                store: StateStore) {
        self.client = client
        self.makeClient = makeClient
        self.store = store
    }
```

4. At the very top of `start()` (before the `do`), load persisted state:

```swift
        persisted = store.load()
        themeRaw = persisted.theme ?? "dark"
        splitPct = persisted.splitPct ?? 38
        recents = persisted.recents
```

5. Add mutators + relaunch + persist, after `reconnect()`:

```swift
    public func setTheme(_ raw: String) {
        guard raw != themeRaw else { return }
        themeRaw = raw
        persist()
    }

    public func setSplitPct(_ pct: Int) {
        let clamped = min(80, max(15, pct))
        guard clamped != splitPct else { return }
        splitPct = clamped
        persist()
    }

    public func relaunchRecent(_ r: RecentSession) async {
        do { _ = try await client.create(dir: r.dir, agent: r.agent, name: r.name) }
        catch { toast = errorText(error) }
    }

    private func persist() {
        persisted.theme = themeRaw
        persisted.splitPct = splitPct
        persisted.recents = recents
        store.save(persisted)
    }
```

6. Split the combined `.sessionRemoved`/`.exited` case in `apply` so only
`.exited` records a recent:

```swift
        case .sessionRemoved(let name):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
        case .exited(let name, _):
            if let s = sessions.first(where: { $0.name == name }) {
                pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent))
                persist()
            }
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
```

In `Sources/covey/App.swift`, build the real store and pass it. Replace the model
construction in the `.task`:

```swift
                    let store = StateStore(path: FileManager.default
                        .homeDirectoryForCurrentUser.appendingPathComponent(".covey/state.json").path)
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient,
                                     store: store)
                    await m.start()
                    model = m
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.AppModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: `Executed <n> tests, with 0 failures` (the 5 new + the slice-5 AppModel tests).
Then the full suite: `xcrun xctest ... | grep "Executed .* tests,"` → 0 failures.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/AppModel.swift Sources/covey/App.swift Tests/CoveyAppTests/AppTestSupport.swift Tests/CoveyAppTests/AppModelTests.swift
git commit -m "feat(covey): AppModel persistence — theme, split, recents"
```

---

### Task 4: Theme, Recent tab, draggable divider (views) + smoke

**Files:**
- Create: `Sources/covey/Theme.swift`
- Modify: `Sources/covey/TerminalController.swift`
- Modify: `Sources/covey/Views/SessionListView.swift`
- Modify: `Sources/covey/Views/ContentView.swift`
- Modify: `Sources/covey/App.swift` (theme toggle in toolbar)

**Interfaces:**
- Consumes: `AppModel.themeRaw`/`splitPct`/`recents`/`setTheme`/`setSplitPct`/`relaunchRecent` (Task 3).
- Produces: runnable app with theme, Recent tab, draggable divider. No new API.

- [ ] **Step 1: Theme + palette**

`Sources/covey/Theme.swift`:

```swift
import AppKit

enum Theme: String {
    case dark, light

    init(raw: String) { self = Theme(rawValue: raw) ?? .dark }

    var background: NSColor {
        switch self {
        case .dark:  return NSColor(red: 0x1C/255, green: 0x19/255, blue: 0x17/255, alpha: 1)
        case .light: return NSColor(red: 0xFA/255, green: 0xF7/255, blue: 0xF2/255, alpha: 1)
        }
    }
    var foreground: NSColor {
        switch self {
        case .dark:  return NSColor(red: 0xFA/255, green: 0xF7/255, blue: 0xF2/255, alpha: 1)
        case .light: return NSColor(red: 0x1C/255, green: 0x19/255, blue: 0x17/255, alpha: 1)
        }
    }
    var cursor: NSColor { .orange }
}
```

- [ ] **Step 2: Terminal reads the theme (make + update)**

In `Sources/covey/TerminalController.swift`, replace the hardcoded colours in
`makeNSView` and apply them from the model, and add live re-theming in
`updateNSView`. Replace the colour lines in `makeNSView`:

```swift
        applyTheme(to: view)
        model.onTerminalOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        applyTheme(to: view)
    }

    private func applyTheme(to view: TerminalView) {
        let theme = Theme(raw: model.themeRaw)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
    }
```

(Delete the old `view.nativeBackgroundColor = NSColor(... 0x1C ...)` block and the
old empty `updateNSView`.)

- [ ] **Step 3: Session list gets Active/Recent picker**

Replace `Sources/covey/Views/SessionListView.swift` body to add a tab picker and a
Recent list. Add a `@State private var tab` and split the two lists:

```swift
import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .active

    enum Tab: String, CaseIterable { case active = "Active", recent = "Recent" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            if tab == .active { activeList } else { recentList }
        }
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
    }

    private var dirs: [String] {
        var seen = Set<String>()
        return model.sessions.map(\.dir).filter { seen.insert($0).inserted }
    }

    private var activeList: some View {
        List(selection: selectionBinding) {
            ForEach(dirs, id: \.self) { dir in
                Section(dir) {
                    ForEach(model.sessions.filter { $0.dir == dir }, id: \.name) { session in
                        row(session)
                            .tag(session.name)
                            .contextMenu {
                                Button("Rename…") { model.modal = .rename(session.name) }
                                Button("Kill…", role: .destructive) { model.modal = .kill(session.name) }
                            }
                    }
                }
            }
        }
    }

    // Recent, newest-first, hiding any name that is currently Active.
    private var recentList: some View {
        let active = Set(model.sessions.map(\.name))
        let items = model.recents.filter { !active.contains($0.name) }
        return List {
            ForEach(items, id: \.name) { r in
                HStack(spacing: 6) {
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name)
                        Text(r.dir).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Relaunch") { Task { await model.relaunchRecent(r) } }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selected },
                set: { name in Task { await model.select(name) } })
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(model.statusByName[session.name] ?? .idle))
                .frame(width: 8, height: 8)
            Text(session.name)
            Spacer()
            Text(session.agent).foregroundStyle(.secondary).font(.caption)
        }
    }

    private func statusColor(_ status: Status) -> Color {
        switch status {
        case .running: return .orange
        case .waiting: return .yellow
        case .idle: return .gray
        }
    }
}
```

- [ ] **Step 4: Draggable divider + colour scheme in ContentView**

Replace `Sources/covey/Views/ContentView.swift` to use a custom split whose width is
driven by `model.splitPct`, and apply the theme's colour scheme:

```swift
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let leftWidth = max(220, min(geo.size.width - 480,
                                         geo.size.width * CGFloat(model.splitPct) / 100))
            HStack(spacing: 0) {
                SessionListView(model: model)
                    .frame(width: leftWidth)
                divider(total: geo.size.width)
                TerminalPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .newSession: NewSessionSheet(model: model)
            case .kill(let name): KillSheet(model: model, name: name)
            case .rename(let name): RenameSheet(model: model, name: name)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        model.setSplitPct(Int(value.location.x / total * 100))
                    }
            )
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast).lineLimit(2)
                if !model.connected {
                    Button("Reconnect") { Task { await model.reconnect() } }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }
}
```

(Note: the divider drag uses `.global` x against the window width — good enough for a
single top-level split; `setSplitPct` clamps to [15, 80].)

- [ ] **Step 5: Theme toggle in the toolbar**

In `Sources/covey/App.swift`, add a toolbar toggle to the `ContentView` branch. Wrap
`ContentView(model: model)` with a `.toolbar`:

```swift
                if let model {
                    ContentView(model: model)
                        .toolbar {
                            Button {
                                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
                            } label: {
                                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
                            }
                            .help("Toggle theme")
                        }
                }
```

- [ ] **Step 6: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 7: Manual smoke (Definition of Done, spec §10)**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock
swift run covey
```

Verify in the app:
1. Toolbar theme toggle → UI and terminal colours flip instantly.
2. Drag the divider → left pane resizes.
3. ⌘Q, `swift run covey` again → theme and split width restored (check `~/.covey/state.json`).
4. Create a session, Kill it → it appears under the Recent tab.
5. Recent → Relaunch → the session comes back under Active.
6. `cat ~/.covey/state.json` → valid JSON with `theme`, `splitPct`, `recents`.

Fix any failure inline (each fix = its own user commit) and re-check.

- [ ] **Step 8: Hand off commit to the user**

```bash
git add Sources/covey/Theme.swift Sources/covey/TerminalController.swift Sources/covey/Views Sources/covey/App.swift
git commit -m "feat(covey): theme toggle, Recent tab, draggable divider"
```

---

## Definition of Done (from spec §10)

1. Build + all tests green (79 prior + PersistedState/StateStore/AppModel additions).
2. Theme toggle applies instantly (UI + terminal) and survives app restart.
3. Split width drags and is restored after restart.
4. Kill → session appears in Recent; Relaunch brings it back to Active.
5. `state.json` is valid JSON, debounced, atomic (no partial/temp files).
