# covey Daemon Registry Persistence + Lost Sessions (Slice 10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The daemon persists its session registry; after a daemon restart the lost sessions surface in the GUI's Recent tab (no auto-respawn).

**Architecture:** A `RegistryStore` (JSON at `~/.covey/registry.json`, daemon-owned) persists `SessionMeta` for live + unclaimed-lost sessions. `SessionRegistry` turns previous-life entries into a `lost` list and reports every mutation through `onPersist`. The `list` response gains an optional `lost` field; a new `clearLost` op acks the GUI's merge into recents. Spec: `docs/superpowers/specs/2026-07-02-covey-daemon-registry-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No network or thread `sleep` in tests; use `waitUntil`/`eventually`/expectations.
- Protocol change is backward-compatible: `lost` is an optional Codable field; old payloads decode with `lost == nil`.
- No auto-respawn: lost sessions are surfaced, never spawned (agreed deviation from HANDOFF §4).
- `registry.json` keeps live + unclaimed-lost metas, so back-to-back daemon restarts do not drop sessions the GUI has not claimed yet.
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Target>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- Full suite: `xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1`.

---

### Task 1: RegistryStore + SessionMeta

**Files:**
- Create: `Sources/CoveydCore/RegistryStore.swift`
- Test: `Tests/CoveydCoreTests/RegistryStoreTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–4):
  - `public struct SessionMeta: Codable, Equatable { name, dir, agent, argv: [String], created: Int64 }` with a public memberwise `init`
  - `public final class RegistryStore { init(path: String); func load() -> [SessionMeta]; func save(_:) }`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/CoveydCore/RegistryStore.swift`:

```swift
import Foundation

/// Metadata needed to surface (and later relaunch) a session that a dead
/// daemon lost: everything but the live process.
public struct SessionMeta: Codable, Equatable {
    public var name: String
    public var dir: String
    public var agent: String
    public var argv: [String]
    public var created: Int64

    public init(name: String, dir: String, agent: String, argv: [String], created: Int64) {
        self.name = name; self.dir = dir; self.agent = agent
        self.argv = argv; self.created = created
    }
}

/// Persists the daemon's session registry (live + unclaimed lost metas) as
/// JSON. Daemon-owned (`~/.covey/registry.json`) — the GUI's `state.json`
/// stays the user-facing record (HANDOFF §8 ownership split).
public final class RegistryStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func load() -> [SessionMeta] {
        []
    }

    public func save(_ metas: [SessionMeta]) {
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveydCoreTests/RegistryStoreTests.swift`:

```swift
import XCTest
@testable import CoveydCore

final class RegistryStoreTests: XCTestCase {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())covey-registry-\(UInt32.random(in: 0..<UInt32.max)).json"
    }

    func testRoundTrip() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let metas = [SessionMeta(name: "s1", dir: "/a", agent: "claude",
                                 argv: ["claude"], created: 42)]
        RegistryStore(path: path).save(metas)
        XCTAssertEqual(RegistryStore(path: path).load(), metas)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(RegistryStore(path: tempPath()).load(), [])
    }

    func testCorruptFileLoadsEmpty() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(RegistryStore(path: path).load(), [])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.RegistryStoreTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 3 tests, 1 failure (`testRoundTrip`; the empty-loading tests pass by construction).

- [ ] **Step 4: Implement**

Replace `load`/`save` bodies:

```swift
    public func load() -> [SessionMeta] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([SessionMeta].self, from: data)) ?? []
    }

    public func save(_ metas: [SessionMeta]) {
        guard let data = try? JSONEncoder().encode(metas) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/CoveydCore/RegistryStore.swift Tests/CoveydCoreTests/RegistryStoreTests.swift
git commit -m "feat(coveyd): RegistryStore — session metadata persistence"
```

---

### Task 2: SessionRegistry — lost sessions + persist callback

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift`
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `SessionMeta` (Task 1).
- Produces (used by Task 3):
  - `init(clock: ... = default, persisted: [SessionMeta] = [], onPersist: (([SessionMeta]) -> Void)? = nil)`
  - `var lost: [SessionMeta]` (locked read), `func clearLost()`
  - `onPersist` fires after create/rename/exit/clearLost with live + lost metas

- [ ] **Step 1: Write the failing tests (append to SessionRegistryTests)**

```swift
    final class PersistSpy {
        private let lock = NSLock()
        private var snapshots: [[SessionMeta]] = []
        func record(_ metas: [SessionMeta]) { lock.lock(); snapshots.append(metas); lock.unlock() }
        var last: [SessionMeta]? { lock.lock(); defer { lock.unlock() }; return snapshots.last }
    }

    func testPersistCallbackTracksLifecycle() throws {
        let spy = PersistSpy()
        let reg = SessionRegistry(clock: { 7 }, onPersist: spy.record)
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "a")
        XCTAssertEqual(spy.last?.map(\.name), ["a"])
        XCTAssertEqual(spy.last?.first?.argv, ["/bin/cat"])
        XCTAssertEqual(spy.last?.first?.created, 7)
        try reg.rename(name: "a", newName: "b")
        XCTAssertEqual(spy.last?.map(\.name), ["b"])
        reg.kill(name: "b")
        waitUntil({ reg.list().isEmpty }, "exit removes entry")
        waitUntil({ spy.last?.isEmpty == true }, "exit persists empty registry")
    }

    func testPersistedEntriesBecomeLostAndClear() {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let spy = PersistSpy()
        let reg = SessionRegistry(persisted: [meta], onPersist: spy.record)
        XCTAssertEqual(reg.lost, [meta])
        XCTAssertTrue(reg.list().isEmpty, "lost sessions are never respawned")
        reg.clearLost()
        XCTAssertTrue(reg.lost.isEmpty)
        XCTAssertEqual(spy.last, [])
    }

    func testPersistIncludesLostUntilClaimed() throws {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let spy = PersistSpy()
        let reg = SessionRegistry(persisted: [meta], onPersist: spy.record)
        _ = try reg.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "new")
        XCTAssertEqual(Set(spy.last?.map(\.name) ?? []), ["new", "old"],
                       "unclaimed lost sessions must survive a second daemon restart")
        reg.kill(name: "new")
        waitUntil({ reg.list().isEmpty }, "cleanup")
    }

    func testSecondLifeSeesFirstLifeSessionsAsLost() throws {
        // Integration with RegistryStore: the daemon-restart scenario.
        let path = "\(NSTemporaryDirectory())covey-registry-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RegistryStore(path: path)
        let first = SessionRegistry(persisted: store.load(), onPersist: { store.save($0) })
        _ = try first.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "s1")
        let second = SessionRegistry(persisted: store.load(), onPersist: { store.save($0) })
        XCTAssertEqual(second.lost.map(\.name), ["s1"])
        first.kill(name: "s1")
        waitUntil({ first.list().isEmpty }, "cleanup")
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

Expected: errors — `persisted:`/`onPersist:`/`lost`/`clearLost` don't exist.

- [ ] **Step 3: Implement**

In `Sources/CoveydCore/SessionRegistry.swift`:

1. Extend the entries tuple with the spawn argv and add the new state. Replace

```swift
    private var entries: [String: (session: Session, process: PTYProcess, screen: ScreenModel)] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0
    
    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) }) {
        self.clock = clock
    }
```

with

```swift
    private var entries: [String: (session: Session, process: PTYProcess, screen: ScreenModel, argv: [String])] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0
    private var lostMetas: [SessionMeta]
    private let onPersist: (([SessionMeta]) -> Void)?

    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) },
                persisted: [SessionMeta] = [],
                onPersist: (([SessionMeta]) -> Void)? = nil) {
        self.clock = clock
        self.lostMetas = persisted   // previous daemon life; surfaced, never respawned
        self.onPersist = onPersist
    }

    /// Sessions from the previous daemon life. The GUI merges them into its
    /// recents and acks with `clearLost()`.
    public var lost: [SessionMeta] {
        lock.lock(); defer { lock.unlock() }
        return lostMetas
    }

    public func clearLost() {
        lock.lock()
        lostMetas = []
        lock.unlock()
        persistNow()
    }

    /// Snapshots live + lost metas under the lock, then persists outside it.
    private func persistNow() {
        guard let onPersist else { return }
        lock.lock()
        let metas = entries.values.map {
            SessionMeta(name: $0.session.name, dir: $0.session.dir,
                        agent: $0.session.agent, argv: $0.argv,
                        created: $0.session.created)
        } + lostMetas
        lock.unlock()
        onPersist(metas)
    }
```

2. In `create`, store argv and persist. Replace

```swift
        if let autoNumber { counter = autoNumber }
        entries[id] = (session, proc, screen)
        lock.unlock()
        onSessionAdded?(session)
        return session
```

with

```swift
        if let autoNumber { counter = autoNumber }
        entries[id] = (session, proc, screen, argv)
        lock.unlock()
        persistNow()
        onSessionAdded?(session)
        return session
```

3. In `rename`, persist after the mutation. Replace

```swift
        entries[name] = nil
        entries[newName] = entry
        lock.unlock()
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
```

with

```swift
        entries[name] = nil
        entries[newName] = entry
        lock.unlock()
        persistNow()
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
```

4. In `handleExit`, persist after the removal. Replace

```swift
    private func handleExit(_ id: String, _ code: Int32) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
        onExit?(id, code)
    }
```

with

```swift
    private func handleExit(_ id: String, _ code: Int32) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
        persistNow()
        onExit?(id, code)
    }
```

(The tuple gains a labeled fourth field; `withEntry`, `attachOutput`,
`snapshotScreens` access fields by name and compile unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveydCoreTests.SessionRegistryTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: all SessionRegistryTests green (13 existing + 3 new = 16 tests, 0 failures).

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(coveyd): registry lost-session tracking + persist callback"
```

---

### Task 3: Protocol `lost` + `clearLost`, IPC wiring, daemon startup

**Files:**
- Modify: `Sources/CoveyKit/Protocol.swift`
- Modify: `Sources/CoveydCore/IPCServer.swift:68-73,118`
- Modify: `Sources/CoveyKit/IPCClient.swift:70-75`
- Modify: `Sources/coveyd/main.swift:35`
- Modify: `Tests/CoveyKitTests/ProtocolTests.swift:36`
- Test: `Tests/CoveydCoreTests/IPCServerTests.swift` (append)

**Interfaces:**
- Consumes: `SessionRegistry.lost/clearLost` (Task 2), `RegistryStore` (Task 1).
- Produces (used by Task 4):
  - `Result.sessions(sessions:statuses:lost: [Session]?)`
  - `Request.Op.clearLost`
  - `IPCClient.list() -> (sessions: [Session], statuses: [String: Status], lost: [Session]?)`
  - `IPCClient.clearLost() async throws`

- [ ] **Step 1: Protocol change**

In `Sources/CoveyKit/Protocol.swift`:

```diff
     public enum Op: Codable, Equatable{
         case list
+        case clearLost
         case create(dir: String, agent: String, argv: [String]?, name: String?)
```

```diff
     public enum Result: Codable, Equatable {
         case ok
         case session(Session)
-        case sessions(sessions: [Session], statuses: [String: Status])
+        // `lost` is optional so payloads from older daemons decode as nil.
+        case sessions(sessions: [Session], statuses: [String: Status], lost: [Session]?)
         case error(code: String, message: String)
     }
```

- [ ] **Step 2: IPCServer**

In `Sources/CoveydCore/IPCServer.swift`, replace the `.list` case:

```swift
        case .list:
            let sessions = registry.list()
            let known = monitor.currentStatuses()
            var statuses: [String: Status] = [:]
            for s in sessions { statuses[s.name] = known[s.name] ?? .idle }
            let lost = registry.lost.map {
                Session(name: $0.name, dir: $0.dir, cwd: $0.dir, agent: $0.agent,
                        created: $0.created, git: nil, worktreeRepo: nil)
            }
            reply(.sessions(sessions: sessions, statuses: statuses,
                            lost: lost.isEmpty ? nil : lost))
```

and add after the `.resize` case:

```swift
        case .clearLost:
            registry.clearLost(); reply(.ok)
```

- [ ] **Step 3: IPCClient**

In `Sources/CoveyKit/IPCClient.swift`, replace `list()`:

```swift
    public func list() async throws -> (sessions: [Session], statuses: [String: Status], lost: [Session]?) {
        if case let .sessions(sessions, statuses, lost) = try await request(.list) {
            return (sessions, statuses, lost)
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected sessions")
    }
```

and add next to `kill(name:)`:

```swift
    public func clearLost() async throws {
        try await expectOK(.clearLost)
    }
```

- [ ] **Step 4: Fix the two existing match/construction sites**

`Tests/CoveyKitTests/ProtocolTests.swift:36` — add the new field:

```swift
            .response(id: 3, result: .sessions(sessions: [s], statuses: ["s-1": .running], lost: [s])),
```

`Tests/CoveydCoreTests/IPCServerTests.swift:76` — widen the pattern:

```swift
            if case .response(2, .sessions(_, let statuses, _)) = $0 {
```

- [ ] **Step 5: Wire the store in coveyd main**

In `Sources/coveyd/main.swift`, replace

```swift
let registry = SessionRegistry()
```

with

```swift
let registryStore = RegistryStore(path: dir.appendingPathComponent("registry.json").path)
let registry = SessionRegistry(persisted: registryStore.load(),
                               onPersist: { registryStore.save($0) })
```

- [ ] **Step 6: Write the IPC test (append to IPCServerTests)**

```swift
    func testListCarriesLostAndClearLostRemoves() {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let registry = SessionRegistry(persisted: [meta])
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .sessions(_, _, let lost)) = $0 { return lost?.map(\.name) == ["old"] }
            return false
        } }, "list carries lost")
        server.handle(Request(id: 2, op: .clearLost), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .ok) = $0 { return true }; return false
        } }, "clearLost acked")
        server.handle(Request(id: 3, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(3, .sessions(_, _, let lost)) = $0 { return lost == nil }
            return false
        } }, "lost cleared")
    }
```

- [ ] **Step 7: Build + affected suites + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -3
xcrun xctest -XCTest CoveydCoreTests.IPCServerTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!` (the compiler will flag any missed `.sessions` match site — fix by adding `, _`), IPCServerTests 5 tests 0 failures, full suite 0 failures.

- [ ] **Step 8: Hand off commit to the user**

```bash
git add Sources/CoveyKit/Protocol.swift Sources/CoveydCore/IPCServer.swift Sources/CoveyKit/IPCClient.swift Sources/coveyd/main.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(covey): lost sessions in list response + clearLost op"
```

---

### Task 4: AppModel — merge lost into recents

**Files:**
- Modify: `Sources/covey/AppModel.swift:88-92`
- Modify: `Tests/CoveyAppTests/AppTestSupport.swift:16-19`
- Test: `Tests/CoveyAppTests/AppModelTests.swift` (append)

**Interfaces:**
- Consumes: `IPCClient.list()` triple + `clearLost()` (Task 3), existing `pushRecent`.
- Produces: lost sessions appear in Recent exactly once.

- [ ] **Step 1: Extend the test harness**

In `Tests/CoveyAppTests/AppTestSupport.swift`, replace the `TestDaemon` init line

```swift
    init() throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
```

with

```swift
    init(persisted: [SessionMeta] = []) throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry(persisted: persisted)
```

- [ ] **Step 2: Write the failing test (append to AppModelTests)**

```swift
    @MainActor
    func testLostSessionsMergeIntoRecentsOnce() async throws {
        let meta = SessionMeta(name: "lost1", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let daemon = try TestDaemon(persisted: [meta]); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-lost-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertTrue(model.recents.contains { $0.name == "lost1" && $0.agent == "claude" })
        store.flush()
        XCTAssertTrue(store.load().recents.contains { $0.name == "lost1" })
        // clearLost was acked: a reconnect must not resurface the session.
        await model.reconnect()
        XCTAssertEqual(model.recents.filter { $0.name == "lost1" }.count, 1)
    }
```

- [ ] **Step 3: Run to verify it fails**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -3
xcrun xctest -XCTest CoveyAppTests.AppModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: compile error first (tuple arity of `client.list()` changed in Task 3 — `AppModel.start` still destructures a pair). If it compiles after adjusting only the destructuring, the test fails on the `recents` assertion.

- [ ] **Step 4: Implement**

In `Sources/covey/AppModel.swift`, inside `start()`, replace

```swift
            let (list, statuses) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            connected = true
            toast = nil
```

with

```swift
            let (list, statuses, lost) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            connected = true
            toast = nil
            if let lost, !lost.isEmpty {
                // Sessions a dead daemon lost: surface them as relaunchable
                // recents, oldest first so the newest ends on top.
                for s in lost.sorted(by: { $0.created < $1.created }) {
                    pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent))
                }
                persist()
                try? await client.clearLost()
            }
```

- [ ] **Step 5: Run tests + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest -XCTest CoveyAppTests.AppModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: AppModelTests green, full suite 0 failures.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/AppModel.swift Tests/CoveyAppTests/AppTestSupport.swift Tests/CoveyAppTests/AppModelTests.swift
git commit -m "feat(covey): surface daemon-lost sessions in Recent"
```

---

### Task 5: Full smoke (Definition of Done, spec §8)

- [ ] **Step 1: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

- [ ] **Step 2: Manual smoke**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock ~/.covey/registry.json
swift run covey
```

1. Create two sessions → `cat ~/.covey/registry.json` shows both (name/dir/agent/argv).
2. Kill one from the UI → registry.json drops it.
3. `pkill -f coveyd` → relaunch covey (daemon auto-starts) → the surviving session
   appears in **Recent** (not Active), relaunchable by click; Active is empty.
4. Relaunch covey again → no duplicates in Recent (`clearLost` acked).
5. Rename a live session → registry.json shows the new name.

Fix any failure inline (each fix = its own user commit) and re-check.

- [ ] **Step 3: Hand off the docs commit to the user**

```bash
git add docs/superpowers/plans/2026-07-02-covey-daemon-registry.md
git commit -m "docs: slice 10 implementation plan — daemon registry + lost sessions"
```

---

## Definition of Done (from spec §8)

1. Build + full suite green (RegistryStore/SessionRegistry/IPC/AppModel tests).
2. Smoke: sessions survive a daemon kill as Recent entries, relaunch works, no dups.
3. `~/.covey/registry.json` tracks create/kill/rename of live sessions.
