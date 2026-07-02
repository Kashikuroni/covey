# covey GUI Chrome (Slice 8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the GUI chrome — topbar (counts/clock/theme/view-switcher), status bar (hints/history/focus), fuzzy filter, drag-reorder, and show_* toggles.

**Architecture:** New AppModel state + pure helpers drive small presentational views (TopBar, StatusBar) and extend the session list. Ordering (`order`/`project_order`) and show_* flags persist through the existing `StateStore`; filter/history/focus are transient. Spec: `docs/superpowers/specs/2026-07-03-covey-gui-chrome-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, XCTest. No new external dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No network or thread `sleep` in tests; AppModel tests use the `TestDaemon` + temp `StateStore` and the shared `eventually` helper.
- Closures on queues/tasks capture `self` via `[weak self]` where they outlive the call.
- View-layer only + AppModel state; no new modules or dependencies.
- Ordering fields (`order`, `projectOrder`) and `show_*` flags already exist in `PersistedState` (slice 6); this slice applies and persists them.
- View-switcher is a stub: Standard/Git segment with Git `.disabled(true)`.
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest CoveyAppTests.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.

---

### Task 1: Fuzzy matcher

**Files:**
- Create: `Sources/covey/Fuzzy.swift`
- Test: `Tests/CoveyAppTests/FuzzyTests.swift`

**Interfaces:**
- Produces (used by Task 4): `func fuzzyMatch(_ pattern: String, _ text: String) -> Bool`

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/Fuzzy.swift`:

```swift
/// Case-insensitive subsequence match: the characters of `pattern` appear in
/// `text` in order (not necessarily contiguously). Empty pattern -> true.
func fuzzyMatch(_ pattern: String, _ text: String) -> Bool {
    false
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/FuzzyTests.swift`:

```swift
import XCTest
@testable import covey

final class FuzzyTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertTrue(fuzzyMatch("cl", "claude"))
        XCTAssertTrue(fuzzyMatch("cd", "claude"))     // non-contiguous
        XCTAssertTrue(fuzzyMatch("claude", "claude"))
    }
    func testNonMatch() {
        XCTAssertFalse(fuzzyMatch("cx", "claude"))
        XCTAssertFalse(fuzzyMatch("dc", "claude"))    // order matters
    }
    func testEmptyPatternMatches() {
        XCTAssertTrue(fuzzyMatch("", "anything"))
    }
    func testCaseInsensitive() {
        XCTAssertTrue(fuzzyMatch("CL", "claude"))
        XCTAssertTrue(fuzzyMatch("cl", "CLAUDE"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.FuzzyTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 4 tests, ≥3 failures.

- [ ] **Step 4: Implement**

```swift
func fuzzyMatch(_ pattern: String, _ text: String) -> Bool {
    if pattern.isEmpty { return true }
    var it = text.lowercased().makeIterator()
    for want in pattern.lowercased() {
        var found = false
        while let c = it.next() {
            if c == want { found = true; break }
        }
        if !found { return false }
    }
    return true
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/Fuzzy.swift Tests/CoveyAppTests/FuzzyTests.swift
git commit -m "feat(covey): fuzzy subsequence matcher"
```

---

### Task 2: AppModel chrome state

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Consumes: `Session`/`Status` (CoveyKit), `PersistedState`/`StateStore` (existing).
- Produces (used by Tasks 3–6):
  - `enum Focus { case sessions, terminal }`
  - state: `order: [String]`, `projectOrder: [String]`, `filter: String`,
    `historyMode: Bool`, `focus: Focus`, `showSessions/showFooter/showHeader: Bool`,
    `filterFocusTick: Int`
  - `var counts: (total: Int, running: Int, waiting: Int)`
  - `func orderedSessions() -> [(dir: String, sessions: [Session])]`
  - mutators: `setFilter(_:)`, `requestFilterFocus()`, `setHistoryMode(_:)`,
    `setFocus(_:)`, `moveSession(inDir:from:to:)`, `moveProject(from:to:)`,
    `setShowSessions(_:)`, `setShowFooter(_:)`, `setShowHeader(_:)`

- [ ] **Step 1: Write the failing tests**

`Tests/CoveyAppTests/AppModelChromeTests.swift`:

```swift
import XCTest
@testable import covey
import CoveyKit
import Foundation

final class AppModelChromeTests: XCTestCase {
    @MainActor
    func testCountsByStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        // statuses arrive from the daemon poller over time; assert total here and
        // running/waiting counters are derived (0 by default before any tick).
        XCTAssertEqual(model.counts.total, 2)
        for s in model.sessions { await model.kill(s.name) }
    }

    @MainActor
    func testOrderedSessionsRespectsOrder() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        // default order = by created (s1 then s2)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s1", "s2"])
        // move s2 before s1
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testMoveSessionPersists() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        store.flush()
        XCTAssertEqual(store.load().order, ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testShowFlagsPersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setShowFooter(false)
        model.setShowHeader(false)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showFooter, false)
        XCTAssertEqual(reloaded.showHeader, false)
    }

    @MainActor
    func testHistoryModeResetsOnSelect() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.setHistoryMode(true)
        XCTAssertTrue(model.historyMode)
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        let other = model.sessions.first { $0.name != name }!.name
        await model.select(other)
        XCTAssertFalse(model.historyMode, "history mode must reset on session switch")
        await model.kill(name); await model.kill(other)
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

Expected: errors — the new state/methods don't exist.

- [ ] **Step 3: Implement the AppModel changes**

In `Sources/covey/AppModel.swift`:

1. Add the enum inside the class (next to `Modal`):

```swift
    public enum Focus { case sessions, terminal }
```

2. Add state after `usageError`:

```swift
    public private(set) var order: [String] = []
    public private(set) var projectOrder: [String] = []
    public var filter: String = ""
    public private(set) var historyMode = false
    public private(set) var focus: Focus = .terminal
    public private(set) var showSessions = true
    public private(set) var showFooter = true
    public private(set) var showHeader = true
    /// Bumped by `requestFilterFocus`; the filter field focuses on change.
    public private(set) var filterFocusTick = 0
```

3. In `start()`, after `recents = persisted.recents`, apply the new persisted fields:

```swift
        order = persisted.order
        projectOrder = persisted.projectOrder
        showSessions = persisted.showSessions ?? true
        showFooter = persisted.showFooter ?? true
        showHeader = persisted.showHeader ?? true
```

4. In `select(_:)`, reset history mode. Change the body so that after `selected = name`
   it also does `historyMode = false`. Add this line right after `outputBuffer = []`:

```swift
        historyMode = false
```

5. Extend `persist()` to write the new persisted fields (keep the existing three):

```swift
    private func persist() {
        persisted.theme = themeRaw
        persisted.splitPct = splitPct
        persisted.recents = recents
        persisted.order = order
        persisted.projectOrder = projectOrder
        persisted.showSessions = showSessions
        persisted.showFooter = showFooter
        persisted.showHeader = showHeader
        store.save(persisted)
    }
```

6. Add computed `counts`, `orderedSessions`, and the mutators (after `relaunchRecent`):

```swift
    public var counts: (total: Int, running: Int, waiting: Int) {
        var r = 0, w = 0
        for s in sessions {
            switch statusByName[s.name] {
            case .running: r += 1
            case .waiting: w += 1
            default: break
            }
        }
        return (sessions.count, r, w)
    }

    /// dir groups ordered by `projectOrder` (unknown dirs appended by first
    /// appearance); within a group, sessions ordered by `order` (unknown by created).
    public func orderedSessions() -> [(dir: String, sessions: [Session])] {
        orderedDirs().map { dir in
            let inDir = sessions.filter { $0.dir == dir }.sorted { a, b in
                let ia = order.firstIndex(of: a.name) ?? Int.max
                let ib = order.firstIndex(of: b.name) ?? Int.max
                if ia != ib { return ia < ib }
                return a.created < b.created
            }
            return (dir, inDir)
        }
    }

    public func setFilter(_ s: String) { filter = s }
    public func requestFilterFocus() { filterFocusTick += 1 }
    public func setHistoryMode(_ on: Bool) { historyMode = on }
    public func setFocus(_ f: Focus) { focus = f }

    public func moveSession(inDir dir: String, from: IndexSet, to: Int) {
        var names = (orderedSessions().first { $0.dir == dir }?.sessions.map(\.name)) ?? []
        names.move(fromOffsets: from, toOffset: to)
        // Rebuild the flat `order` across every dir in its current order.
        var newOrder: [String] = []
        for group in orderedSessions() {
            newOrder.append(contentsOf: group.dir == dir ? names : group.sessions.map(\.name))
        }
        order = newOrder
        persist()
    }

    public func moveProject(from: IndexSet, to: Int) {
        var dirs = orderedDirs()
        dirs.move(fromOffsets: from, toOffset: to)
        projectOrder = dirs
        persist()
    }

    public func setShowSessions(_ on: Bool) { showSessions = on; persist() }
    public func setShowFooter(_ on: Bool) { showFooter = on; persist() }
    public func setShowHeader(_ on: Bool) { showHeader = on; persist() }

    private func orderedDirs() -> [String] {
        var seen = Set<String>(); var dirs: [String] = []
        for d in projectOrder where sessions.contains(where: { $0.dir == d }) {
            if seen.insert(d).inserted { dirs.append(d) }
        }
        for s in sessions where !seen.contains(s.dir) {
            if seen.insert(s.dir).inserted { dirs.append(s.dir) }
        }
        return dirs
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.AppModelChromeTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: 5 chrome tests pass; full suite 0 failures.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): AppModel chrome state — order, counts, flags, focus"
```

---

### Task 3: TopBar + StatusBar + ContentView layout

**Files:**
- Create: `Sources/covey/Views/TopBar.swift`
- Create: `Sources/covey/Views/StatusBar.swift`
- Modify: `Sources/covey/Views/ContentView.swift`
- Modify: `Sources/covey/App.swift` (drop the toolbar theme toggle)

**Interfaces:**
- Consumes: `AppModel.counts/themeRaw/setTheme/historyMode/focus/showHeader/showFooter` (Task 2).
- Produces: chrome layout wrapping the workspace.

- [ ] **Step 1: TopBar**

`Sources/covey/Views/TopBar.swift`:

```swift
import SwiftUI

struct TopBar: View {
    @Bindable var model: AppModel
    @State private var view: ViewKind = .standard
    enum ViewKind: String, CaseIterable { case standard = "Standard", git = "Git" }

    var body: some View {
        HStack(spacing: 12) {
            Text("covey").fontWeight(.semibold)
            let c = model.counts
            Text("\(c.total) · ▶\(c.running) · ⏸\(c.waiting)")
                .foregroundStyle(.secondary).font(.callout)
            Spacer()
            Picker("", selection: $view) {
                Text("Standard").tag(ViewKind.standard)
                Text("Git").tag(ViewKind.git).disabled(true)   // stub target
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button {
                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
            } label: {
                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
            }
            .buttonStyle(.borderless).help("Toggle theme")
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(clock(ctx.date)).foregroundStyle(.secondary).font(.callout).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
```

- [ ] **Step 2: StatusBar**

`Sources/covey/Views/StatusBar.swift`:

```swift
import SwiftUI

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("⌘N new · ⌘F filter").foregroundStyle(.secondary).font(.caption)
            Spacer()
            if model.historyMode {
                Text("HISTORY").foregroundStyle(.yellow).font(.caption).fontWeight(.semibold)
            }
            Text(model.focus == .sessions ? "sessions" : "terminal")
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
```

- [ ] **Step 3: Wrap the workspace in ContentView**

Replace `Sources/covey/Views/ContentView.swift` `body` so the split workspace sits
between the optional TopBar and StatusBar:

```swift
    var body: some View {
        VStack(spacing: 0) {
            if model.showHeader { TopBar(model: model); Divider() }
            workspace
            if model.showFooter { Divider(); StatusBar(model: model) }
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

    private var workspace: some View {
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
    }
```

(Keep the existing `divider(total:)` and `toastBar` helpers unchanged. The
`show_sessions`-driven pane hiding + focus taps land in Task 6.)

- [ ] **Step 4: Remove the toolbar theme toggle from App.swift**

The theme toggle now lives in TopBar. In `Sources/covey/App.swift`, delete the
`.toolbar { Button { model.setTheme(...) } ... }` block attached to
`ContentView(model: model)`, leaving just `ContentView(model: model)`.

- [ ] **Step 5: Build + full suite + partial smoke**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures. Then `swift run covey`: a top bar (name,
counts, Standard|Git with Git greyed, theme toggle, clock) and a bottom status bar
appear; theme toggle still flips colours. Quit with ⌘Q.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/Views/TopBar.swift Sources/covey/Views/StatusBar.swift Sources/covey/Views/ContentView.swift Sources/covey/App.swift
git commit -m "feat(covey): top bar + status bar chrome"
```

---

### Task 4: Fuzzy filter + menu commands

**Files:**
- Modify: `Sources/covey/Views/SessionListView.swift`
- Modify: `Sources/covey/App.swift` (`.commands`)

**Interfaces:**
- Consumes: `fuzzyMatch` (Task 1), `AppModel.filter/setFilter/requestFilterFocus/filterFocusTick/modal` (Task 2).
- Produces: filter bar + ⌘N/⌘F commands.

- [ ] **Step 1: Add the filter bar to the Active tab**

In `Sources/covey/Views/SessionListView.swift`, add a `@FocusState` and a filter
`TextField` above the active list, and filter the rows through `fuzzyMatch`. Add at
the top of the struct:

```swift
    @FocusState private var filterFocused: Bool
```

Insert the filter field into `body`, right after the `Picker(...)` block, only for the
Active tab:

```swift
            if tab == .active {
                TextField("Filter", text: Binding(
                    get: { model.filter }, set: { model.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .padding(.horizontal, 6)
                    .onChange(of: model.filterFocusTick) { _, _ in filterFocused = true }
            }
```

Change `activeList` to filter each dir's sessions through `fuzzyMatch` and drop empty
sections. Replace the `ForEach(model.sessions.filter { $0.dir == dir })` inner content
by filtering on the name; replace the whole `activeList` computed property:

```swift
    private var activeList: some View {
        List(selection: selectionBinding) {
            ForEach(dirs, id: \.self) { dir in
                let rows = model.sessions
                    .filter { $0.dir == dir && fuzzyMatch(model.filter, $0.name) }
                if !rows.isEmpty {
                    Section(dir) {
                        ForEach(rows, id: \.name) { session in
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
    }
```

(`dirs` and the rest of `SessionListView` are unchanged. Ordered grouping arrives in
Task 5 — this task keeps the existing `dirs` grouping.)

- [ ] **Step 2: Add menu commands in App.swift**

In `Sources/covey/App.swift`, attach `.commands` to the `WindowGroup` scene. After the
`WindowGroup("covey") { ... }` closing brace (still inside `body`), add:

```swift
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Session") { model?.modal = .newSession }
                        .keyboardShortcut("n", modifiers: .command)
                }
                CommandGroup(after: .textEditing) {
                    Button("Filter Sessions") { model?.requestFilterFocus() }
                        .keyboardShortcut("f", modifiers: .command)
                }
            }
```

- [ ] **Step 3: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures (fuzzyMatch already unit-tested in Task 1).

- [ ] **Step 4: Partial smoke**

`swift run covey`: create a couple of sessions; typing in the filter narrows the list
by subsequence; ⌘F focuses the filter field; ⌘N opens New Session. Quit.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/covey/Views/SessionListView.swift Sources/covey/App.swift
git commit -m "feat(covey): fuzzy session filter + menu commands"
```

---

### Task 5: Drag-reorder

**Files:**
- Modify: `Sources/covey/Views/SessionListView.swift`

**Interfaces:**
- Consumes: `AppModel.orderedSessions/moveSession/moveProject/filter` (Task 2).
- Produces: reorder gestures wired to persisted order.

- [ ] **Step 1: Drive the active list from `orderedSessions` with onMove**

Replace `activeList` in `Sources/covey/Views/SessionListView.swift` so it renders from
`model.orderedSessions()` and supports reordering. Reorder is enabled only when the
filter is empty (a filtered list is read-only):

```swift
    private var activeList: some View {
        let groups = model.orderedSessions()
        let filtering = !model.filter.isEmpty
        return List(selection: selectionBinding) {
            ForEach(groups, id: \.dir) { group in
                let rows = group.sessions.filter { fuzzyMatch(model.filter, $0.name) }
                if !rows.isEmpty {
                    Section(group.dir) {
                        ForEach(rows, id: \.name) { session in
                            row(session)
                                .tag(session.name)
                                .contextMenu {
                                    Button("Rename…") { model.modal = .rename(session.name) }
                                    Button("Kill…", role: .destructive) { model.modal = .kill(session.name) }
                                }
                        }
                        .onMove { from, to in
                            guard !filtering else { return }
                            model.moveSession(inDir: group.dir, from: from, to: to)
                        }
                    }
                }
            }
        }
    }
```

Note: project (section) reorder via a nested `onMove` is not reliably supported by
SwiftUI's sectioned `List`; `moveProject` exists and persists, but this slice wires only
the row-level (within-project) reorder gesture. Project order still applies from
`state.json` and can be exercised by tests. Drop the now-unused `dirs` computed property
if the compiler warns it is unused.

- [ ] **Step 2: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|warning: .*never used|Build complete" | tail -3
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures. If a `dirs`-unused warning appears, delete the
`private var dirs` property.

- [ ] **Step 3: Partial smoke**

`swift run covey`: with two sessions in one directory and an empty filter, drag one
above the other; quit and relaunch (`swift run covey`) — the order is preserved
(`cat ~/.covey/state.json` shows `order`).

- [ ] **Step 4: Hand off commit to the user**

```bash
git add Sources/covey/Views/SessionListView.swift
git commit -m "feat(covey): drag-reorder sessions within a project"
```

---

### Task 6: History-mode, focus, show_* toggles + smoke

**Files:**
- Modify: `Sources/covey/TerminalController.swift`
- Modify: `Sources/covey/Views/ContentView.swift`
- Modify: `Sources/covey/App.swift` (View menu toggles)

**Interfaces:**
- Consumes: `AppModel.setHistoryMode/setFocus/showSessions/setShowSessions/setShowFooter/setShowHeader` (Task 2).
- Produces: the wired indicators + visibility toggles; completes the slice.

- [ ] **Step 1: Wire the terminal scroll to history mode**

In `Sources/covey/TerminalController.swift`, replace the no-op `scrolled` in the
`Coordinator` with:

```swift
        func scrolled(source: TerminalView, position: Double) {
            // position 1.0 == pinned to the live bottom; anything less is history.
            let history = position < 0.999
            Task { @MainActor in model.setHistoryMode(history) }
        }
```

- [ ] **Step 2: Focus taps + show_sessions pane hiding in ContentView**

In `Sources/covey/Views/ContentView.swift`, hide the left pane when
`!model.showSessions`, and set focus on tap. Replace `workspace`:

```swift
    private var workspace: some View {
        GeometryReader { geo in
            let leftWidth = max(220, min(geo.size.width - 480,
                                         geo.size.width * CGFloat(model.splitPct) / 100))
            HStack(spacing: 0) {
                if model.showSessions {
                    SessionListView(model: model)
                        .frame(width: leftWidth)
                        .onTapGesture { model.setFocus(.sessions) }
                    divider(total: geo.size.width)
                }
                TerminalPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { model.setFocus(.terminal) }
            }
        }
    }
```

- [ ] **Step 3: View menu toggles in App.swift**

Add a `CommandMenu("View")` to the `.commands` block in `Sources/covey/App.swift`
(alongside the Task 4 groups):

```swift
                CommandMenu("View") {
                    Toggle("Show Sessions", isOn: Binding(
                        get: { model?.showSessions ?? true },
                        set: { model?.setShowSessions($0) }))
                    Toggle("Show Top Bar", isOn: Binding(
                        get: { model?.showHeader ?? true },
                        set: { model?.setShowHeader($0) }))
                    Toggle("Show Status Bar", isOn: Binding(
                        get: { model?.showFooter ?? true },
                        set: { model?.setShowFooter($0) }))
                }
```

- [ ] **Step 4: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 5: Full manual smoke (Definition of Done, spec §11)**

```bash
pkill -f coveyd 2>/dev/null; rm -f ~/.covey/coveyd.sock
swift run covey
```

Verify:
1. Top bar counts update as you create/kill sessions; clock shows `HH:mm`; Git segment
   is visible but greyed; theme toggle flips colours.
2. Select a session, scroll the terminal up → status bar shows `HISTORY`; scroll back to
   the bottom → it clears. Status bar shows `sessions`/`terminal` as you click panes.
3. Filter narrows the list; ⌘F focuses it; ⌘N opens New.
4. Drag two sessions in one project to reorder; relaunch → order preserved.
5. View menu: toggle Show Sessions / Top Bar / Status Bar → panes hide/show; relaunch →
   the toggles persist.

Fix any failure inline (each fix = its own user commit) and re-check.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/TerminalController.swift Sources/covey/Views/ContentView.swift Sources/covey/App.swift
git commit -m "feat(covey): history-mode indicator, focus, show_* toggles"
```

---

## Definition of Done (from spec §11)

1. Build + all tests green (prior suite + Fuzzy/AppModelChrome).
2. Top bar: live counts, running clock, working theme toggle, disabled Git segment.
3. Status bar: `HISTORY` on scroll-up, clears at bottom; shows active pane.
4. Fuzzy filter narrows the list; ⌘F focuses it; ⌘N opens New.
5. Drag-reorder within a project persists across restart.
6. View toggles hide/show session pane, top bar, status bar; persist across restart.
