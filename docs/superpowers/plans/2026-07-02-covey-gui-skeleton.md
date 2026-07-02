# covey GUI Walking Skeleton (Slice 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable SwiftUI app: window with session list + live SwiftTerm terminal over IPCClient, sheets for New/Kill/Rename, daemon auto-start.

**Architecture:** SwiftPM executable `covey`; `@Observable @MainActor AppModel` owns the single `client.events` loop (daemon is the source of truth — UI actions call the client, the model mutates only on events); SwiftTerm `TerminalView` bridged via `NSViewRepresentable`, remounted per session with `.id`. Spec: `docs/superpowers/specs/2026-07-02-covey-gui-skeleton-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, SwiftTerm ≥ 1.13.0, XCTest (async, `@MainActor`).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No thread `sleep` in tests; async polling via `Task.sleep` suspension is allowed.
- Closures on queues/sources capture `self` via `[weak self]`; view captured `[weak view]`.
- TDD for AppModel (skeleton → failing test → implementation); views are compile-checked and verified by the Task 4 manual smoke.
- Test run pattern: `swift build --build-tests`, then
  `xcrun xctest -XCTest CoveyAppTests.AppModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- `client.events` is single-consumer — only AppModel's event loop iterates it.
- SwiftTerm facts (verified against main): `TerminalViewDelegate` has NO default
  implementations — implement all 12 methods; `view.feed(byteArray:)` takes
  `ArraySlice<UInt8>`; colors via `nativeBackgroundColor` / `nativeForegroundColor` /
  `caretColor` (NSColor).

---

### Task 1: App target scaffold

**Files:**
- Modify: `Package.swift` (two new targets)
- Create: `Sources/covey/App.swift`
- Create: `Sources/covey/Views/ContentView.swift` (placeholder body, replaced in Task 3)

**Interfaces:**
- Produces: executable target `covey` (deps: CoveyKit, SwiftTerm), test target `CoveyAppTests` (deps: covey, CoveydCore); `CoveyApp.makeClient() throws -> IPCClient` used by Task 3's wiring.

- [ ] **Step 1: Add targets to Package.swift**

Insert after the `coveyd` executableTarget:

```swift
        .executableTarget(
            name: "covey",
            dependencies: [
                "CoveyKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

and after the `CoveyKitTests` testTarget:

```swift
        .testTarget(
            name: "CoveyAppTests",
            dependencies: ["covey", "CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 2: Create the minimal app**

`Sources/covey/App.swift`:

```swift
import AppKit
import SwiftUI
import CoveyKit

@main
struct CoveyApp: App {
    @State private var model: AppModelBox = AppModelBox()

    init() {
        // SwiftPM executables launch as accessory processes; become a real app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("covey") {
            ContentView()
        }
    }

    /// ensureDaemon + connect. The daemon binary lives next to our own binary —
    /// true both for `.build/debug` (swift run) and for a future .app bundle.
    static func makeClient() throws -> IPCClient {
        let binDir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent()
        let daemonBinary = binDir.appendingPathComponent("coveyd").path
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/coveyd.sock").path
        try DaemonLauncher.ensureDaemon(socketPath: socket, binaryPath: daemonBinary)
        let client = IPCClient(path: socket)
        try client.connect()
        return client
    }
}

/// Placeholder holder so App compiles before AppModel exists (Task 2 replaces usage).
final class AppModelBox {}
```

`Sources/covey/Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("covey skeleton")
            .frame(minWidth: 700, minHeight: 400)
    }
}
```

- [ ] **Step 3: Build and manually verify the window opens**

```bash
swift build 2>&1 | tail -1
```

Expected: `Build complete!`. Then run `swift run covey` — a window titled "covey"
with "covey skeleton" appears; quit with ⌘Q. (Manual check; no assertion.)

- [ ] **Step 4: Run the full suite (regression)**

```bash
swift build --build-tests && xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests" | tail -1
```

Expected: 70 tests, 0 failures, 1 skipped.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Package.swift Sources/covey/App.swift Sources/covey/Views/ContentView.swift
git commit -m "feat(covey): SwiftUI app target scaffold"
```

---

### Task 2: AppModel

**Files:**
- Create: `Sources/covey/AppModel.swift`
- Create: `Tests/CoveyAppTests/AppTestSupport.swift`
- Test: `Tests/CoveyAppTests/AppModelTests.swift`
- Modify: `Sources/covey/App.swift` (drop `AppModelBox`)

**Interfaces:**
- Consumes: `IPCClient` (slice 4), `Session`/`Status`/`DaemonEvent` (CoveyKit); in tests `SessionRegistry`/`StatusMonitor`/`IPCServer`/`SocketServer` (CoveydCore).
- Produces (used by Task 3):
  - `AppModel(client: IPCClient, makeClient: @escaping () throws -> IPCClient)` — `@Observable @MainActor`
  - state: `sessions: [Session]`, `statusByName: [String: Status]`, `selected: String?`, `modal: Modal?` (`.newSession`, `.kill(String)`, `.rename(String)`), `toast: String?`, `connected: Bool`
  - `onTerminalOutput: (([UInt8]) -> Void)?`
  - actions: `start()`, `select(_:)`, `create(dir:agent:)`, `kill(_:)`, `rename(_:to:)`, `sendInput(_:)`, `resize(cols:rows:)`, `reconnect()` — all `async`

- [ ] **Step 1: Write the compilable skeleton**

Replace `Sources/covey/AppModel.swift` content (new file):

```swift
import Foundation
import Observation
import CoveyKit

/// UI state machine. The daemon is the single source of truth about sessions:
/// actions call the IPC client and the model mutates only when the daemon's
/// events confirm the change. One instance owns the single `client.events`
/// consumer (the stream delivers each element to exactly one iterator).
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable {
        case newSession
        case kill(String)
        case rename(String)
    }

    public private(set) var sessions: [Session] = []       // sorted by created
    public private(set) var statusByName: [String: Status] = [:]
    public private(set) var selected: String?
    public var modal: Modal?
    public private(set) var toast: String?
    public private(set) var connected = false

    /// Bytes for the currently attached session's terminal view.
    /// Set by TerminalRepresentable on mount, cleared on dismantle.
    public var onTerminalOutput: (([UInt8]) -> Void)?

    private var client: IPCClient
    private let makeClient: () throws -> IPCClient
    private var eventLoop: Task<Void, Never>?

    public init(client: IPCClient, makeClient: @escaping () throws -> IPCClient) {
        self.client = client
        self.makeClient = makeClient
    }

    public func start() async {
    }

    public func select(_ name: String?) async {
    }

    public func create(dir: String, agent: String) async {
    }

    public func kill(_ name: String) async {
    }

    public func rename(_ name: String, to newName: String) async {
    }

    public func sendInput(_ bytes: [UInt8]) async {
    }

    public func resize(cols: UInt16, rows: UInt16) async {
    }

    public func reconnect() async {
    }
}
```

In `Sources/covey/App.swift` delete the `AppModelBox` class and the
`@State private var model: AppModelBox = AppModelBox()` line (Task 3 wires the
real model). Run `swift build --build-tests 2>&1 | tail -1` → `Build complete!`.

- [ ] **Step 2: Write the test harness**

`Tests/CoveyAppTests/AppTestSupport.swift`:

```swift
import Foundation
import XCTest
@testable import covey
import CoveyKit
import CoveydCore

/// In-process daemon stack on a temp socket path (deliberate copy of the
/// CoveyKitTests harness — test targets cannot import each other).
final class TestDaemon {
    let path: String
    let registry: SessionRegistry
    let monitor: StatusMonitor
    private let ipc: IPCServer
    private let server: SocketServer

    init() throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        ipc = IPCServer(registry: registry, monitor: monitor)
        server = SocketServer(path: path)
        let ipc = self.ipc
        server.onAccept = { conn in
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
    /// Model + the client it talks through (kept for close()-driven tests).
    @MainActor
    func makeModel(_ daemon: TestDaemon) throws -> (AppModel, IPCClient) {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        let path = daemon.path
        let model = AppModel(client: client, makeClient: {
            let c = IPCClient(path: path)
            try c.connect()
            return c
        })
        return (model, client)
    }

    /// Polls a MainActor condition every 20 ms until true or timeout.
    func eventually(timeout: TimeInterval = 5,
                    _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: cond) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/CoveyAppTests/AppModelTests.swift`:

```swift
import XCTest
@testable import covey
import CoveyKit
import CoveydCore

final class AppModelTests: XCTestCase {
    @MainActor
    func testStartListsExistingSessionsAndConnects() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/usr", agent: "sh",
                                       argv: ["/bin/cat"], name: "pre")
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.sessions.map(\.name), ["pre"])
        daemon.registry.kill(name: "pre")
    }

    @MainActor
    func testCreateAddsSessionViaEvent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        let appeared = await eventually { model.sessions.count == 1 }
        XCTAssertTrue(appeared, "sessionAdded event did not land in model")
        await model.kill(model.sessions[0].name)
    }

    @MainActor
    func testStatusChangedUpdatesMap() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        let (model, _) = try makeModel(daemon)
        await model.start()
        let rendered = await eventually {
            daemon.registry.snapshotScreens()["menu"]?.contains("2. no") == true
        }
        XCTAssertTrue(rendered)
        daemon.monitor.tick()
        let updated = await eventually { model.statusByName["menu"] == .waiting }
        XCTAssertTrue(updated, "statusChanged did not land in model")
        daemon.registry.kill(name: "menu")
    }

    @MainActor
    func testKillRemovesSessionAndClearsSelection() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        XCTAssertEqual(model.selected, name)
        await model.kill(name)
        let gone = await eventually { model.sessions.isEmpty && model.selected == nil }
        XCTAssertTrue(gone)
    }

    @MainActor
    func testOutputRoutesOnlyForSelectedSession() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let a = model.sessions[0].name
        await model.select(a)

        var received: [UInt8] = []
        model.onTerminalOutput = { received.append(contentsOf: $0) }
        await model.sendInput(Array("ping\n".utf8))
        let got = await eventually {
            String(decoding: received, as: UTF8.self).contains("ping")
        }
        XCTAssertTrue(got, "selected session's output did not reach the terminal callback")
        await model.kill(a)
    }

    @MainActor
    func testClientCloseFlipsConnectedAndSetsToast() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, client) = try makeModel(daemon)
        await model.start()
        XCTAssertTrue(model.connected)
        client.close()
        let dropped = await eventually { !model.connected && model.toast != nil }
        XCTAssertTrue(dropped, "stream end did not flip connected/toast")
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.AppModelTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 6 tests, 6 failures (stubs do nothing).

- [ ] **Step 5: Implement AppModel**

Replace the stub bodies in `Sources/covey/AppModel.swift` and add the private
section:

```swift
    public func start() async {
        do {
            let (list, statuses) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            connected = true
            toast = nil
        } catch {
            connected = false
            toast = errorText(error)
            return
        }
        eventLoop?.cancel()
        // Inherits MainActor: apply() and the trailing mutations run on the actor.
        eventLoop = Task { [client] in
            for await event in client.events {
                self.apply(event)
            }
            self.connected = false
            self.toast = "daemon connection lost"
        }
    }

    public func select(_ name: String?) async {
        guard name != selected else { return }
        if let old = selected {
            try? await client.detach(name: old)
        }
        selected = name
        if let name {
            do { try await client.attach(name: name, sinceSeq: 0) }
            catch { toast = errorText(error) }
        }
    }

    public func create(dir: String, agent: String) async {
        do { _ = try await client.create(dir: dir, agent: agent) }
        catch { toast = errorText(error) }
    }

    public func kill(_ name: String) async {
        do { try await client.kill(name: name) }
        catch { toast = errorText(error) }
    }

    public func rename(_ name: String, to newName: String) async {
        do { try await client.rename(name: name, newName: newName) }
        catch { toast = errorText(error) }
    }

    public func sendInput(_ bytes: [UInt8]) async {
        guard let selected else { return }
        try? await client.input(name: selected, bytes: bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) async {
        guard let selected else { return }
        try? await client.resize(name: selected, cols: cols, rows: rows)
    }

    public func reconnect() async {
        do {
            client = try makeClient()
            toast = nil
        } catch {
            toast = errorText(error)
            return
        }
        await start()
        if let name = selected {           // re-attach after the new connect
            selected = nil
            await select(name)
        }
    }

    // MARK: - private

    private func apply(_ event: DaemonEvent) {
        switch event {
        case let .sessionAdded(session):
            sessions.removeAll { $0.name == session.name }
            sessions.append(session)
            sessions.sort { $0.created < $1.created }
        case .sessionRemoved(let name), .exited(let name, _):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
        case let .statusChanged(name, status):
            statusByName[name] = status
        case let .output(name, _, bytesB64):
            if name == selected, let data = Data(base64Encoded: bytesB64) {
                onTerminalOutput?([UInt8](data))
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if case let IPCClientError.daemonError(code, message) = error {
            return "\(code): \(message)"
        }
        return "\(error)"
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Same command as Step 4. Expected: `Executed 6 tests, with 0 failures`.
Full suite: 76 tests, 0 failures, 1 skipped.

- [ ] **Step 7: Hand off commit to the user**

```bash
git add Sources/covey/AppModel.swift Sources/covey/App.swift Tests/CoveyAppTests/AppTestSupport.swift Tests/CoveyAppTests/AppModelTests.swift
git commit -m "feat(covey): observable AppModel over IPC client"
```

---

### Task 3: Terminal bridge + views + wiring

**Files:**
- Create: `Sources/covey/TerminalController.swift`
- Create: `Sources/covey/Views/SessionListView.swift`
- Create: `Sources/covey/Views/TerminalPaneView.swift`
- Create: `Sources/covey/Views/Sheets.swift`
- Modify: `Sources/covey/Views/ContentView.swift` (real layout)
- Modify: `Sources/covey/App.swift` (model bootstrap)

**Interfaces:**
- Consumes: `AppModel` (Task 2, exact API from its Interfaces block), `CoveyApp.makeClient()` (Task 1), SwiftTerm `TerminalView`.
- Produces: runnable app; no new API for later tasks.

- [ ] **Step 1: Terminal bridge**

`Sources/covey/TerminalController.swift`:

```swift
import AppKit
import SwiftUI
import SwiftTerm

/// SwiftTerm TerminalView bridged into SwiftUI, render-only: the daemon owns
/// the process. Keystrokes go to the daemon (`send` -> input), bytes come back
/// through `model.onTerminalOutput`. The hosting view remounts this per
/// session via `.id(sessionName)`.
struct TerminalRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // Hardcoded dark theme (HANDOFF §5); theme switching arrives in slice 6.
        view.nativeBackgroundColor = NSColor(red: 0x1C / 255, green: 0x19 / 255,
                                             blue: 0x17 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0xFA / 255, green: 0xF7 / 255,
                                             blue: 0xF2 / 255, alpha: 1)
        view.caretColor = .orange
        model.onTerminalOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        Task { @MainActor in coordinator.model.onTerminalOutput = nil }
    }

    // Not MainActor-isolated: TerminalViewDelegate requirements are nonisolated,
    // so an isolated class could not satisfy them. Calls hop to the actor inside.
    final class Coordinator: TerminalViewDelegate {
        let model: AppModel
        init(model: AppModel) { self.model = model }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in await model.sendInput(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let (cols, rows) = (UInt16(newCols), UInt16(newRows))
            Task { @MainActor in await model.resize(cols: cols, rows: rows) }
        }

        // The daemon owns process state; the rest of the delegate is unused.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
```

- [ ] **Step 2: Session list**

`Sources/covey/Views/SessionListView.swift`:

```swift
import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel

    private var dirs: [String] {
        var seen = Set<String>()
        return model.sessions.map(\.dir).filter { seen.insert($0).inserted }
    }

    var body: some View {
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
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selected },
            set: { name in Task { await model.select(name) } }
        )
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(model.statusByName[session.name] ?? .idle))
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

- [ ] **Step 3: Terminal pane + sheets + content view**

`Sources/covey/Views/TerminalPaneView.swift`:

```swift
import SwiftUI
import CoveyKit

struct TerminalPaneView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.selected,
               let session = model.sessions.first(where: { $0.name == name }) {
                header(session)
                Divider()
                TerminalRepresentable(model: model)
                    .id(name)   // fresh TerminalView per session (spec §5)
            } else {
                Spacer()
                Text("no session selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func header(_ session: CoveyKit.Session) -> some View {
        HStack(spacing: 8) {
            Text(session.name).fontWeight(.semibold)
            Text(session.dir).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(session.agent).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
```

`Sources/covey/Views/Sheets.swift`:

```swift
import AppKit
import SwiftUI

extension AppModel.Modal: Identifiable {
    public var id: String {
        switch self {
        case .newSession: return "new"
        case .kill(let name): return "kill-\(name)"
        case .rename(let name): return "rename-\(name)"
        }
    }
}

struct NewSessionSheet: View {
    let model: AppModel
    @State private var dir = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var agent = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session").font(.headline)
            HStack {
                TextField("Directory", text: $dir)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        dir = url.path
                    }
                }
            }
            TextField("Agent", text: $agent)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Create") {
                    let (d, a) = (dir, agent)
                    Task {
                        await model.create(dir: d, agent: a)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(dir.isEmpty || agent.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct KillSheet: View {
    let model: AppModel
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Kill session \"\(name)\"?").font(.headline)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Kill", role: .destructive) {
                    Task {
                        await model.kill(name)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct RenameSheet: View {
    let model: AppModel
    let name: String
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \"\(name)\"").font(.headline)
            TextField("New name", text: $newName)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    let target = newName
                    Task {
                        await model.rename(name, to: target)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { newName = name }
    }
}
```

`Sources/covey/Views/ContentView.swift` (replace):

```swift
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SessionListView(model: model)
                .frame(minWidth: 220, maxWidth: 420)
            TerminalPaneView(model: model)
                .frame(minWidth: 480, minHeight: 320)
        }
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .newSession: NewSessionSheet(model: model)
            case .kill(let name): KillSheet(model: model, name: name)
            case .rename(let name): RenameSheet(model: model, name: name)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
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

- [ ] **Step 4: Bootstrap the model in App.swift**

Replace the `body` of `CoveyApp` (keep `init` and `makeClient` as is):

```swift
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup("covey") {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let startupError {
                    VStack(spacing: 10) {
                        Text("failed to start").font(.headline)
                        Text(startupError).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 700, minHeight: 400)
                } else {
                    ProgressView("starting daemon…")
                        .frame(minWidth: 700, minHeight: 400)
                }
            }
            .task {
                guard model == nil else { return }
                do {
                    let m = AppModel(client: try CoveyApp.makeClient(),
                                     makeClient: CoveyApp.makeClient)
                    await m.start()
                    model = m
                } catch {
                    startupError = "\(error)"
                }
            }
        }
    }
```

- [ ] **Step 5: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests" | tail -1
```

Expected: `Build complete!`, 76 tests, 0 failures, 1 skipped.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/TerminalController.swift Sources/covey/Views/ Sources/covey/App.swift
git commit -m "feat(covey): session list, terminal pane, sheets — runnable skeleton"
```

---

### Task 4: Manual smoke (Definition of Done)

**Files:** none (fixes, if any, land as their own commits).

**Interfaces:** none — this task verifies spec §8 end-to-end.

- [ ] **Step 1: Clean slate + launch**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock
swift run covey
```

Expected: window opens; daemon auto-starts (check `ls ~/.covey/coveyd.sock`).

- [ ] **Step 2: Walk the checklist (manual, in the app)**

1. ＋ → New session: dir = home, agent = `sh` → Create. Session appears in the
   list, selected → terminal shows a shell prompt.
2. Type `echo hello` + Enter → output appears (input + output path).
3. Resize the window → `stty size` in the shell reports new rows/cols (resize path).
4. `sleep 2` in the shell → list glyph turns orange (running) then gray (idle).
5. Context menu → Rename… → new name shows in the list.
6. Context menu → Kill… → session disappears, terminal pane shows placeholder.
7. Create a session again, ⌘Q the app, `swift run covey` again → session is
   still in the list (daemon survived), click it → scrollback backfill renders.
8. `pkill -9 -f coveyd` in another terminal → toast "daemon connection lost"
   appears with a Reconnect button; press Reconnect → daemon respawns, list loads.

- [ ] **Step 3: Record results**

Note any failures; fix inline (each fix = separate commit via the user) and
re-run the failing checklist item. When all 8 pass, slice 5 DoD is met.

---

## Definition of Done (from spec §8)

1. Build + all tests green (70 old + 6 new AppModelTests).
2. `swift run covey` opens the window; daemon auto-starts or is reused.
3. Live interactive terminal: input, output, resize reaches the PTY.
4. Status glyphs change live (running/waiting/idle).
5. Kill/Rename work from the UI; daemon errors surface as toasts.
6. GUI restart keeps sessions; re-attach backfills scrollback.
