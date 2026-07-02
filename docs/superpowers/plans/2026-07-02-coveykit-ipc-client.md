# CoveyKit IPCClient (Slice 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Client side of the NDJSON unix-socket protocol — async/await `IPCClient` + `DaemonLauncher.ensureDaemon` in CoveyKit, for the future SwiftUI GUI.

**Architecture:** GCD transport (POSIX socket + read `DispatchSource`, `LineFramer`) bridged to async/await via checked continuations keyed by request id; daemon events flow through one unbounded `AsyncStream<DaemonEvent>`. `NDJSONCodec` moves from CoveydCore to CoveyKit so both sides share framing. Spec: `docs/superpowers/specs/2026-07-02-coveykit-ipc-client-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, XCTest (async tests), no new external dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command to hand over.
- No `sleep` in XCTest code — `XCTestExpectation` / async helpers with `Task` timeouts. (The 50 ms poll inside `DaemonLauncher` is library code, not a test.)
- Closures on queues/sources capture `self` via `[weak self]`; fd captured by value in cancel handlers.
- `sockaddr_un` filling uses the hoisted `pathSize` pattern (Swift exclusivity).
- TDD per memory `tdd-skeleton-first`: compilable skeleton → failing test → implementation.
- Test run pattern: `swift build --build-tests`, then
  `xcrun xctest -XCTest CoveyKitTests.<ClassName> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`
  (dot-separated). Full suite: bundle without `-XCTest`.
- `client.events` is a single-consumer stream: each element is delivered to exactly one
  `for await` iterator. Tests must not run two competing consumers.

---

### Task 1: Move NDJSONCodec to CoveyKit

**Files:**
- Move: `Sources/CoveydCore/NDJSONCodec.swift` → `Sources/CoveyKit/NDJSONCodec.swift` (content unchanged)
- Move: `Tests/CoveydCoreTests/NDJSONCodecTests.swift` → `Tests/CoveyKitTests/NDJSONCodecTests.swift` (import changes)

**Interfaces:**
- Produces: `NDJSON.encodeLine(_:)`, `NDJSON.decoder`, `LineFramer`, `NDJSONError` now exported by `CoveyKit`. `CoveydCore` users (`Connection.swift`) keep compiling because CoveydCore already imports CoveyKit and all uses are unqualified.

- [ ] **Step 1: Move both files**

```bash
mv Sources/CoveydCore/NDJSONCodec.swift Sources/CoveyKit/NDJSONCodec.swift
mv Tests/CoveydCoreTests/NDJSONCodecTests.swift Tests/CoveyKitTests/NDJSONCodecTests.swift
```

In `Tests/CoveyKitTests/NDJSONCodecTests.swift` change the import line
`@testable import CoveydCore` → `@testable import CoveyKit`.

- [ ] **Step 2: Run the full suite**

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | tail -3
```

Expected: `Executed 60 tests, with 0 failures` (same count, tests just moved suites).

- [ ] **Step 3: Hand off commit to the user**

```bash
git add Sources/CoveydCore/NDJSONCodec.swift Sources/CoveyKit/NDJSONCodec.swift Tests/CoveydCoreTests/NDJSONCodecTests.swift Tests/CoveyKitTests/NDJSONCodecTests.swift
git commit -m "refactor(coveykit): move NDJSON codec from CoveydCore to CoveyKit"
```

(`git add` on both old and new paths lets git record the rename.)

---

### Task 2: IPCClient — connect + request/response

**Files:**
- Modify: `Package.swift` (CoveyKitTests gains CoveydCore dependency)
- Create: `Sources/CoveyKit/UnixSocket.swift`
- Create: `Sources/CoveyKit/IPCClient.swift`
- Create: `Tests/CoveyKitTests/ClientTestSupport.swift`
- Test: `Tests/CoveyKitTests/IPCClientTests.swift`

**Interfaces:**
- Consumes: `NDJSON`/`LineFramer` (Task 1), protocol types from `Protocol.swift`, in tests — `SessionRegistry`/`StatusMonitor`/`IPCServer`/`SocketServer` from CoveydCore.
- Produces (used by Tasks 3–4):
  - `IPCClientError: Error, Equatable` — `.notConnected`, `.connectFailed(Int32)`, `.daemonError(code: String, message: String)`, `.disconnected`
  - `IPCClient(path: String)`, `connect() throws`, `close()`, `events: AsyncStream<DaemonEvent>`
  - typed methods: `list()`, `create(dir:agent:argv:name:)`, `kill(name:)`, `rename(name:newName:)`, `attach(name:sinceSeq:)`, `detach(name:)`, `input(name:bytes:)`, `resize(name:cols:rows:)`
  - `UnixSocket.connect(_ fd: Int32, to path: String) -> Int32` (internal helper)
  - test harness `TestDaemon` (in-process server stack on a temp socket path)

- [ ] **Step 1: Add the test-target dependency**

In `Package.swift`:

```swift
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit", "CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

Run `swift build --build-tests 2>&1 | tail -1`. Expected: `Build complete!`.

- [ ] **Step 2: Write the compilable skeletons**

`Sources/CoveyKit/UnixSocket.swift`:

```swift
import Darwin
import Foundation

/// Shared sockaddr_un plumbing for unix-domain socket clients.
enum UnixSocket {
    /// connect(2) `fd` to the unix socket at `path`.
    /// Returns 0 on success, -1 on failure (errno set by the syscall).
    static func connect(_ fd: Int32, to path: String) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathSize) {
                    strlcpy($0, src, pathSize)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
    }
}
```

`Sources/CoveyKit/IPCClient.swift` (skeleton — stubs throw/return placeholders):

```swift
import Darwin
import Foundation

public enum IPCClientError: Error, Equatable {
    case notConnected                                  // request before connect() / after close()
    case connectFailed(Int32)                          // errno from connect(2), or ETIMEDOUT
    case daemonError(code: String, message: String)    // .error result from the daemon
    case disconnected                                  // EOF/teardown while a request was pending
}

/// Client side of the coveyd NDJSON unix-socket protocol. One instance = one
/// connection; after a disconnect the instance is dead — the GUI runs
/// `DaemonLauncher.ensureDaemon` and builds a fresh client (HANDOFF "GUI
/// restart" semantics). All mutable state is confined to the serial `queue`.
public final class IPCClient {
    /// Every daemon event, including `output`. Single long-lived stream,
    /// unbounded buffer, finishes on EOF or `close()`.
    public let events: AsyncStream<DaemonEvent>

    private let path: String
    private let queue = DispatchQueue(label: "covey.ipc-client")
    private let eventsContinuation: AsyncStream<DaemonEvent>.Continuation
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var pending: [Int: CheckedContinuation<ServerMessage.Result, Error>] = [:]
    private var nextID = 0
    private var connected = false
    private var closed = false

    public init(path: String) {
        self.path = path
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: DaemonEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        readSource?.cancel()          // closes the fd via the cancel handler
        eventsContinuation.finish()
    }

    public func connect() throws {
        throw IPCClientError.notConnected
    }

    public func close() {
    }

    // MARK: - typed requests

    public func list() async throws -> (sessions: [Session], statuses: [String: Status]) {
        if case let .sessions(sessions, statuses) = try await request(.list) {
            return (sessions, statuses)
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected sessions")
    }

    public func create(dir: String, agent: String, argv: [String]? = nil,
                       name: String? = nil) async throws -> Session {
        if case let .session(s) = try await request(
            .create(dir: dir, agent: agent, argv: argv, name: name)) {
            return s
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected session")
    }

    public func kill(name: String) async throws {
        try await expectOK(.kill(name: name))
    }

    public func rename(name: String, newName: String) async throws {
        try await expectOK(.rename(name: name, newName: newName))
    }

    public func attach(name: String, sinceSeq: Int? = nil) async throws {
        try await expectOK(.attach(name: name, sinceSeq: sinceSeq))
    }

    public func detach(name: String) async throws {
        try await expectOK(.detach(name: name))
    }

    public func input(name: String, bytes: [UInt8]) async throws {
        try await expectOK(.input(name: name, bytesB64: Data(bytes).base64EncodedString()))
    }

    public func resize(name: String, cols: UInt16, rows: UInt16) async throws {
        try await expectOK(.resize(name: name, cols: cols, rows: rows))
    }

    // MARK: - private

    private func expectOK(_ op: Request.Op) async throws {
        if case .ok = try await request(op) { return }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected ok")
    }

    private func request(_ op: Request.Op) async throws -> ServerMessage.Result {
        throw IPCClientError.notConnected
    }
}
```

Run `swift build --build-tests 2>&1 | tail -1`. Expected: `Build complete!`.

- [ ] **Step 3: Write the test harness and failing tests**

`Tests/CoveyKitTests/ClientTestSupport.swift`:

```swift
import Foundation
import XCTest
@testable import CoveyKit
import CoveydCore

/// In-process daemon stack on a temp socket path, for client integration tests.
final class TestDaemon {
    let path: String
    let registry: SessionRegistry
    let monitor: StatusMonitor
    private let ipc: IPCServer
    private let server: SocketServer

    /// `mute: true` accepts connections but wires no handlers, so requests
    /// get no responses — for pending/disconnect tests.
    init(mute: Bool = false) throws {
        path = "\(NSTemporaryDirectory())covey-kit-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        ipc = IPCServer(registry: registry, monitor: monitor)
        server = SocketServer(path: path)
        let ipc = self.ipc
        server.onAccept = { conn in
            guard !mute else { conn.start(); return }
            ipc.register(conn)
            conn.onRequest = { req, c in ipc.handle(req, from: c) }
            conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
            conn.onClose = { c in ipc.unregister(c) }
            conn.start()
        }
        try server.start()
    }

    func stop() { server.stop() }
}

extension XCTestCase {
    /// First event matching `pred`, or nil after `timeout`. Single consumer:
    /// do not run two of these against the same client concurrently.
    func awaitEvent(_ client: IPCClient, timeout: TimeInterval = 5,
                    where pred: @escaping (DaemonEvent) -> Bool) async -> DaemonEvent? {
        let consumer = Task { () -> DaemonEvent? in
            for await e in client.events where pred(e) { return e }
            return nil
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            consumer.cancel()
        }
        let result = await consumer.value
        timer.cancel()
        return result
    }
}
```

`Tests/CoveyKitTests/IPCClientTests.swift`:

```swift
import XCTest
@testable import CoveyKit
import CoveydCore

final class IPCClientTests: XCTestCase {
    func testRequestBeforeConnectThrowsNotConnected() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        do {
            _ = try await client.list()
            XCTFail("expected notConnected")
        } catch let e as IPCClientError {
            XCTAssertEqual(e, .notConnected)
        }
    }

    func testConnectToMissingSocketThrowsConnectFailed() {
        let client = IPCClient(path: "\(NSTemporaryDirectory())covey-nope.sock")
        do {
            try client.connect()
            XCTFail("expected connectFailed")
        } catch IPCClientError.connectFailed {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testListOnEmptyRegistry() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }
        let (sessions, statuses) = try await client.list()
        XCTAssertEqual(sessions, [])
        XCTAssertEqual(statuses, [:])
    }

    func testCreateReturnsSessionAndKillGhostThrowsNotFound() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        let s = try await client.create(dir: "/usr", agent: "sh",
                                        argv: ["/bin/cat"], name: "c1")
        XCTAssertEqual(s.name, "c1")
        try await client.kill(name: "c1")

        do {
            try await client.kill(name: "ghost")
            XCTFail("expected notFound")
        } catch let IPCClientError.daemonError(code, _) {
            XCTAssertEqual(code, "notFound")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyKitTests.IPCClientTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 4 tests, ≥3 failures (`connect()` stub throws, `request` stub throws
`notConnected` — the first test may already pass; that is fine).

- [ ] **Step 5: Implement connect + request/response**

Replace the `connect`, `close`, and `request` stubs in
`Sources/CoveyKit/IPCClient.swift`, and add the private transport methods:

```swift
    public func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw IPCClientError.connectFailed(errno) }
        guard UnixSocket.connect(sock, to: path) == 0 else {
            let e = errno
            Darwin.close(sock)
            throw IPCClientError.connectFailed(e)
        }
        queue.sync {
            fd = sock
            connected = true
            let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
            src.setEventHandler { [weak self] in self?.handleReadable() }
            src.setCancelHandler { Darwin.close(sock) }
            readSource = src
            src.resume()
        }
    }

    public func close() {
        queue.async { [weak self] in self?.teardown() }
    }
```

```swift
    private func request(_ op: Request.Op) async throws -> ServerMessage.Result {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    return cont.resume(throwing: IPCClientError.disconnected)
                }
                guard self.connected, !self.closed else {
                    return cont.resume(throwing: IPCClientError.notConnected)
                }
                self.nextID += 1
                let id = self.nextID
                guard let line = try? NDJSON.encodeLine(Request(id: id, op: op)) else {
                    return cont.resume(throwing: IPCClientError.daemonError(
                        code: "badResponse", message: "request encoding failed"))
                }
                self.pending[id] = cont
                self.writeLine(line)
            }
        }
    }

    /// On `queue`. A failed write is not reported here: the read side will
    /// observe EOF and tear down, failing all pending requests.
    private func writeLine(_ line: [UInt8]) {
        line.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n > 0 {
                    base = base.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// On `queue`.
    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            guard let lines = try? framer.feed(Array(buf[0..<n])) else { return teardown() }
            for line in lines { dispatchLine(line) }
        } else {
            teardown()
        }
    }

    /// On `queue`. Unparseable lines are ignored (trust the daemon, don't die).
    private func dispatchLine(_ line: [UInt8]) {
        guard let msg = try? NDJSON.decoder.decode(ServerMessage.self, from: Data(line)) else {
            return
        }
        switch msg {
        case let .response(id, result):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if case let .error(code, message) = result {
                cont.resume(throwing: IPCClientError.daemonError(code: code, message: message))
            } else {
                cont.resume(returning: result)
            }
        case .event:
            break   // wired to `events` in the events task
        }
    }

    /// On `queue`. Idempotent: EOF, close(), and framer errors all land here.
    private func teardown() {
        guard !closed else { return }
        closed = true
        connected = false
        readSource?.cancel()      // cancel handler closes the fd
        readSource = nil
        fd = -1
        for (_, cont) in pending {
            cont.resume(throwing: IPCClientError.disconnected)
        }
        pending.removeAll()
        eventsContinuation.finish()
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Same command as Step 4. Expected: `Executed 4 tests, with 0 failures`.
Then the full suite:

```bash
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests" | tail -1
```

Expected: 64 tests, 0 failures.

- [ ] **Step 7: Hand off commit to the user**

```bash
git add Package.swift Sources/CoveyKit/UnixSocket.swift Sources/CoveyKit/IPCClient.swift Tests/CoveyKitTests/ClientTestSupport.swift Tests/CoveyKitTests/IPCClientTests.swift
git commit -m "feat(coveykit): async IPC client — connect + request/response"
```

---

### Task 3: IPCClient — events stream + disconnect lifecycle

**Files:**
- Modify: `Sources/CoveyKit/IPCClient.swift` (the `case .event:` branch in `dispatchLine`)
- Test: `Tests/CoveyKitTests/IPCClientTests.swift` (append)

**Interfaces:**
- Consumes: everything from Task 2 (`IPCClient`, `TestDaemon`, `awaitEvent`).
- Produces: working `events` stream; documented lifecycle — `close()`/EOF fails
  pending requests with `.disconnected`, finishes `events`, later requests throw
  `.notConnected`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CoveyKitTests/IPCClientTests.swift` (inside the class):

```swift
    func testAttachInputStreamsOutputEvent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        _ = try await client.create(dir: "/usr", agent: "sh",
                                    argv: ["/bin/cat"], name: "s1")
        try await client.attach(name: "s1")
        try await client.input(name: "s1", bytes: Array("ping\n".utf8))

        let event = await awaitEvent(client) { e in
            if case let .output(_, _, b64) = e, let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self).contains("ping")
            }
            return false
        }
        XCTAssertNotNil(event, "no output event with 'ping' within timeout")
        try await client.kill(name: "s1")
    }

    func testStatusChangedArrivesViaEvents() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        _ = try await client.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        // Wait until the daemon-side screen shows the menu, then tick once.
        let consumer = Task { [monitor = daemon.monitor, registry = daemon.registry] in
            while registry.snapshotScreens()["menu"]?.contains("2. no") != true {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            monitor.tick()
        }
        let event = await awaitEvent(client) { e in
            if case .statusChanged("menu", .waiting) = e { return true }
            return false
        }
        consumer.cancel()
        XCTAssertNotNil(event, "no statusChanged(waiting) within timeout")
        try await client.kill(name: "menu")
    }

    func testCloseFailsPendingRequestWithDisconnected() async throws {
        let daemon = try TestDaemon(mute: true)   // accepts, never responds
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()

        let pending = Task { () -> IPCClientError? in
            do { _ = try await client.list(); return nil }
            catch let e as IPCClientError { return e }
            catch { return nil }
        }
        // Give the request a moment to become pending, then close underneath it.
        try await Task.sleep(nanoseconds: 100_000_000)
        client.close()
        let error = await pending.value
        XCTAssertEqual(error, .disconnected)

        // events must be finished: iteration ends immediately.
        let leftover = await awaitEvent(client, timeout: 1) { _ in true }
        XCTAssertNil(leftover)

        // subsequent requests fail fast.
        do {
            _ = try await client.list()
            XCTFail("expected notConnected")
        } catch let e as IPCClientError {
            XCTAssertEqual(e, .notConnected)
        }
    }
```

Note: the single `Task.sleep` here is async suspension, not a thread `sleep`;
it does not block the test runner and is the standard way to yield in async tests.

- [ ] **Step 2: Run tests to verify the events tests fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyKitTests.IPCClientTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 7 tests, 2 failures (both `awaitEvent`-based tests time out because
`dispatchLine` drops events; the lifecycle test already passes via Task 2's
teardown — it is a regression guard).

- [ ] **Step 3: Implement the event branch**

In `Sources/CoveyKit/IPCClient.swift`, `dispatchLine`:

```swift
        case let .event(e):
            eventsContinuation.yield(e)
```

(replacing `case .event: break   // wired to `events` in the events task`).

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Executed 7 tests, with 0 failures`.
Full suite: 67 tests, 0 failures.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveyKit/IPCClient.swift Tests/CoveyKitTests/IPCClientTests.swift
git commit -m "feat(coveykit): daemon events stream + disconnect lifecycle"
```

---

### Task 4: DaemonLauncher + gated smoke test

**Files:**
- Create: `Sources/CoveyKit/DaemonLauncher.swift`
- Test: `Tests/CoveyKitTests/DaemonLauncherTests.swift`

**Interfaces:**
- Consumes: `UnixSocket.connect` (Task 2), `IPCClientError` (Task 2), `IPCClient` (Tasks 2–3, in the smoke test).
- Produces: `DaemonLauncher.ensureDaemon(socketPath: String, binaryPath: String, timeout: TimeInterval = 5) throws`.

- [ ] **Step 1: Write the compilable skeleton**

`Sources/CoveyKit/DaemonLauncher.swift`:

```swift
import Darwin
import Foundation

public enum DaemonLauncher {
    /// Returns once a live daemon accepts connections on `socketPath`.
    /// If nothing accepts, spawns `binaryPath` and polls every 50 ms up to
    /// `timeout`, then throws `connectFailed(ETIMEDOUT)`. A stale socket file
    /// is NOT removed here — the daemon does that itself on startup.
    public static func ensureDaemon(socketPath: String, binaryPath: String,
                                    timeout: TimeInterval = 5) throws {
        throw IPCClientError.connectFailed(ETIMEDOUT)
    }

    /// True if connect(2) on the unix socket succeeds (a live daemon accepts).
    private static func probe(_ path: String) -> Bool {
        false
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyKitTests/DaemonLauncherTests.swift`:

```swift
import XCTest
@testable import CoveyKit
import CoveydCore

final class DaemonLauncherTests: XCTestCase {
    func testAliveSocketIsNoOp() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        // binaryPath is bogus: if ensureDaemon tried to spawn, it would throw.
        try DaemonLauncher.ensureDaemon(socketPath: daemon.path,
                                        binaryPath: "/nonexistent-daemon",
                                        timeout: 0.3)
    }

    func testDeadSocketTimesOut() {
        let path = "\(NSTemporaryDirectory())covey-dead-\(UInt32.random(in: 0..<UInt32.max)).sock"
        do {
            // /usr/bin/false exits immediately and never creates the socket.
            try DaemonLauncher.ensureDaemon(socketPath: path,
                                            binaryPath: "/usr/bin/false",
                                            timeout: 0.3)
            XCTFail("expected connectFailed")
        } catch IPCClientError.connectFailed {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // Real-daemon smoke (DoD §7.2-3). Run manually:
    //   COVEY_SMOKE=1 xcrun xctest -XCTest CoveyKitTests.DaemonLauncherTests \
    //     .build/arm64-apple-macosx/debug/coveyPackageTests.xctest
    func testSmokeRealDaemonRoundTripAndKill() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COVEY_SMOKE"] == "1",
                          "smoke test; set COVEY_SMOKE=1 to run")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaemonLauncherTests.swift
            .deletingLastPathComponent()   // CoveyKitTests
            .deletingLastPathComponent()   // Tests
        let binary = root.appendingPathComponent(".build/debug/coveyd").path
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/coveyd.sock").path

        try DaemonLauncher.ensureDaemon(socketPath: socket, binaryPath: binary)
        let client = IPCClient(path: socket)
        try client.connect()

        let s = try await client.create(dir: "/usr", agent: "sh",
                                        argv: ["/bin/cat"], name: "smoke")
        XCTAssertEqual(s.name, "smoke")
        try await client.attach(name: "smoke")
        try await client.input(name: "smoke", bytes: Array("ping\n".utf8))
        let output = await awaitEvent(client) { e in
            if case let .output(_, _, b64) = e, let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self).contains("ping")
            }
            return false
        }
        XCTAssertNotNil(output)

        // kill -9 the daemon: pending request fails, events stream ends.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-f", binary]
        try killer.run()
        killer.waitUntilExit()

        let ended = await awaitEvent(client, timeout: 5) { _ in false }
        XCTAssertNil(ended)   // stream finished (or timed out — finish is the pass)
        do {
            _ = try await client.list()
            XCTFail("expected notConnected or disconnected")
        } catch let e as IPCClientError {
            XCTAssertTrue(e == .notConnected || e == .disconnected)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyKitTests.DaemonLauncherTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 3 tests, 1 failure (`testAliveSocketIsNoOp` — stub always throws;
timeout test passes by luck of the stub, smoke skips).

- [ ] **Step 4: Implement**

Replace the stubs in `Sources/CoveyKit/DaemonLauncher.swift`:

```swift
    public static func ensureDaemon(socketPath: String, binaryPath: String,
                                    timeout: TimeInterval = 5) throws {
        if probe(socketPath) { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        try proc.run()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe(socketPath) { return }
            usleep(50_000)
        }
        throw IPCClientError.connectFailed(ETIMEDOUT)
    }

    private static func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return UnixSocket.connect(fd, to: path) == 0
    }
```

Note: `try proc.run()` throwing (bad binaryPath) propagates as its own error —
`testAliveSocketIsNoOp` relies on never reaching the spawn.

- [ ] **Step 5: Run tests to verify they pass, then the full suite**

Same command as Step 3. Expected: `Executed 3 tests, with 0 failures (1 skipped)` —
xctest counts the skip inside the executed total.

```bash
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests" | tail -1
```

Expected: 70 tests, 0 failures.

- [ ] **Step 6: Run the real-daemon smoke (DoD)**

```bash
pkill -f '.build/debug/coveyd'; rm -f ~/.covey/coveyd.sock
swift build 2>&1 | tail -1
COVEY_SMOKE=1 xcrun xctest -XCTest CoveyKitTests.DaemonLauncherTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed|passed|failed" | tail -3
pkill -f '.build/debug/coveyd' 2>/dev/null; true
```

Expected: 3 tests, 0 failures, 0 skipped — ensureDaemon spawned the real daemon,
round-trip worked, kill -9 produced clean disconnect semantics.

- [ ] **Step 7: Hand off commit to the user**

```bash
git add Sources/CoveyKit/DaemonLauncher.swift Tests/CoveyKitTests/DaemonLauncherTests.swift
git commit -m "feat(coveykit): daemon launcher with socket probe + spawn"
```

---

## Definition of Done (from spec §7)

1. Full suite green (60 old + ~10 new, including moved NDJSONCodecTests).
2. Smoke (Task 4 Step 6): ensureDaemon spawns the real daemon; client creates a
   session, receives `output` and `statusChanged`; `list` carries statuses.
3. `kill -9` of the daemon: pending request throws `.disconnected` (or fast
   `.notConnected` after teardown), `events` finishes — no hangs.
4. `CoveydCore` builds without its own NDJSONCodec.
