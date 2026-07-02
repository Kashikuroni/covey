# covey UI Polish (Slice 11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inspector placeholder pane with persisted width/visibility, Session menu with ⌘W kill / ⌘⇧R rename, ⌘1/2/3 focus, inert Vim Mode toggle — closes the last phase-1 gap.

**Architecture:** Three new persisted AppModel fields (`showInspector`, `sbWidth`, `vimMode`) drive an `InspectorView` third pane and new menu commands. ⌘W is intercepted by a local keyDown NSEvent monitor (the slice-9 pattern) because File→Close would otherwise shadow it. Spec: `docs/superpowers/specs/2026-07-02-covey-ui-polish-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- No network or thread `sleep` in tests; AppModel tests use `TestDaemon` + temp `StateStore` + `eventually`.
- `sbWidth` clamps to `240...600`; defaults: `showInspector=false`, `sbWidth=360`, `vimMode=false`.
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Target>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- Full suite: `xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1`.

---

### Task 1: Persisted inspector/vim state in AppModel

**Files:**
- Modify: `Sources/CoveyKit/PersistedState.swift`
- Modify: `Sources/covey/AppModel.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift` (append), `Tests/CoveyAppTests/StateStoreTests.swift` (append)

**Interfaces:**
- Produces (used by Task 2/3): `AppModel.showInspector/sbWidth/vimMode`,
  `setShowInspector(_:)`, `setSbWidth(_:)`, `setVimMode(_:)`, `Focus.inspector`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CoveyAppTests/AppModelChromeTests.swift`:

```swift
    @MainActor
    func testInspectorAndVimStatePersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-inspector-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertFalse(model.showInspector)
        XCTAssertEqual(model.sbWidth, 360)
        XCTAssertFalse(model.vimMode)
        model.setShowInspector(true)
        model.setSbWidth(420)
        model.setVimMode(true)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showInspector, true)
        XCTAssertEqual(reloaded.sbWidth, 420)
        XCTAssertEqual(reloaded.vimMode, true)
        // A fresh model over the same store loads them back.
        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let model2 = AppModel(client: client2,
                              makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                              store: StateStore(path: path, debounce: 0.05))
        await model2.start()
        XCTAssertTrue(model2.showInspector)
        XCTAssertEqual(model2.sbWidth, 420)
        XCTAssertTrue(model2.vimMode)
    }

    @MainActor
    func testSbWidthClampsAndFocusInspector() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.setSbWidth(100)
        XCTAssertEqual(model.sbWidth, 240)
        model.setSbWidth(9000)
        XCTAssertEqual(model.sbWidth, 600)
        model.setFocus(.inspector)
        XCTAssertEqual(model.focus, .inspector)
    }
```

Append to `Tests/CoveyAppTests/StateStoreTests.swift`:

```swift
    func testInspectorAndVimFieldsRoundTrip() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)
        var s = PersistedState()
        s.showInspector = true
        s.vimMode = true
        s.sbWidth = 300
        store.save(s)
        store.flush()
        let back = StateStore(path: path).load()
        XCTAssertEqual(back.showInspector, true)
        XCTAssertEqual(back.vimMode, true)
        XCTAssertEqual(back.sbWidth, 300)
    }
```

Note: `Focus` needs `Equatable` semantics for `XCTAssertEqual` — a Swift enum
without associated values already provides it.

- [ ] **Step 2: Run to verify it fails to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

Expected: errors — `showInspector`/`vimMode` fields and mutators don't exist.

- [ ] **Step 3: Implement**

1. `Sources/CoveyKit/PersistedState.swift` — add two fields after `showHeader`:

```swift
    public var showInspector: Bool?
    public var vimMode: Bool?
```

and extend the memberwise init parameter list and assignments accordingly:

```swift
        showSessions: Bool? = nil, showFooter: Bool? = nil, showHeader: Bool? = nil,
        showInspector: Bool? = nil, vimMode: Bool? = nil,
        lastVersion: String? = nil
```

```swift
        self.showSessions = showSessions; self.showFooter = showFooter
        self.showHeader = showHeader
        self.showInspector = showInspector; self.vimMode = vimMode
        self.lastVersion = lastVersion
```

2. `Sources/covey/AppModel.swift`:

- `Focus` enum: `public enum Focus { case sessions, terminal, inspector }`
- state after `showHeader`:

```swift
    public private(set) var showInspector = false
    public private(set) var sbWidth = 360
    public private(set) var vimMode = false
```

- in `start()` after the `showHeader` load line:

```swift
        showInspector = persisted.showInspector ?? false
        sbWidth = persisted.sbWidth ?? 360
        vimMode = persisted.vimMode ?? false
```

- mutators next to `setShowHeader`:

```swift
    public func setShowInspector(_ on: Bool) { showInspector = on; persist() }
    public func setVimMode(_ on: Bool) { vimMode = on; persist() }

    public func setSbWidth(_ px: Int) {
        let clamped = min(600, max(240, px))
        guard clamped != sbWidth else { return }
        sbWidth = clamped
        persist()
    }
```

- `persist()` additions:

```swift
        persisted.showInspector = showInspector
        persisted.sbWidth = sbWidth
        persisted.vimMode = vimMode
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.AppModelChromeTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest -XCTest CoveyAppTests.StateStoreTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: both classes 0 failures.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/CoveyKit/PersistedState.swift Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift Tests/CoveyAppTests/StateStoreTests.swift
git commit -m "feat(covey): inspector/vim persisted state + Focus.inspector"
```

---

### Task 2: InspectorView + third pane + ⌘W monitor

**Files:**
- Create: `Sources/covey/Views/InspectorView.swift`
- Modify: `Sources/covey/Views/ContentView.swift`
- Modify: `Sources/covey/Views/StatusBar.swift`

**Interfaces:**
- Consumes: `AppModel.showInspector/sbWidth/setSbWidth/setFocus/selected/modal` (Task 1).

- [ ] **Step 1: InspectorView**

`Sources/covey/Views/InspectorView.swift`:

```swift
import SwiftUI

/// Placeholder for the inspector pane; notes/diffs arrive in a later slice.
struct InspectorView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Inspector").font(.headline).foregroundStyle(.secondary)
            Text("Notes and diffs arrive in a later slice")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Third pane + right divider + ⌘W monitor in ContentView**

In `Sources/covey/Views/ContentView.swift`:

1. Add the monitor state at the top of the struct:

```swift
    @State private var keyMonitor: Any?
```

2. Replace `workspace`:

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
                if model.showInspector {
                    rightDivider(total: geo.size.width)
                    InspectorView()
                        .frame(width: CGFloat(model.sbWidth))
                        .contentShape(Rectangle())
                        .onTapGesture { model.setFocus(.inspector) }
                }
            }
        }
    }

    private func rightDivider(total: CGFloat) -> some View {
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
                        model.setSbWidth(Int(total - value.location.x))
                    }
            )
    }
```

3. Attach the ⌘W monitor to `body` (after `.overlay(alignment: .bottom) { toastBar }`):

```swift
        .onAppear {
            // File→Close would shadow a menu ⌘W (AppKit picks the first key
            // equivalent in menu order), so intercept before dispatch.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.charactersIgnoringModifiers == "w",
                      model.modal == nil,
                      let selected = model.selected else { return event }
                model.modal = .kill(selected)
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
```

4. In `Sources/covey/Views/StatusBar.swift`, replace the focus label:

```swift
            Text(focusLabel).foregroundStyle(.secondary).font(.caption)
```

with the computed property added below `body`:

```swift
    private var focusLabel: String {
        switch model.focus {
        case .sessions: return "sessions"
        case .terminal: return "terminal"
        case .inspector: return "inspector"
        }
    }
```

- [ ] **Step 3: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 4: Hand off commit to the user**

```bash
git add Sources/covey/Views/InspectorView.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/StatusBar.swift
git commit -m "feat(covey): inspector placeholder pane + cmd-W kill intercept"
```

---

### Task 3: Session menu + View menu additions

**Files:**
- Modify: `Sources/covey/App.swift` (`.commands`)

**Interfaces:**
- Consumes: `AppModel.selected/modal/showInspector/setShowInspector/setFocus/vimMode/setVimMode` (Tasks 1–2).

- [ ] **Step 1: Add the Session menu and extend the View menu**

In `Sources/covey/App.swift`, inside `.commands`, after the `.textEditing` group:

```swift
            CommandMenu("Session") {
                Button("Kill Session…") {
                    if let selected = model?.selected { model?.modal = .kill(selected) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model?.selected == nil)
                Button("Rename Session…") {
                    if let selected = model?.selected { model?.modal = .rename(selected) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selected == nil)
            }
```

and extend `CommandMenu("View")` (after the three existing toggles):

```swift
                    Toggle("Show Inspector", isOn: Binding(
                        get: { model?.showInspector ?? false },
                        set: { model?.setShowInspector($0) }))
                    Divider()
                    Button("Focus Sessions") { model?.setFocus(.sessions) }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Focus Terminal") { model?.setFocus(.terminal) }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Focus Inspector") { model?.setFocus(.inspector) }
                        .keyboardShortcut("3", modifiers: .command)
                        .disabled(model?.showInspector != true)
                    Divider()
                    Toggle("Vim Mode", isOn: Binding(
                        get: { model?.vimMode ?? false },
                        set: { model?.setVimMode($0) }))
```

- [ ] **Step 2: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 3: Hand off commit to the user**

```bash
git add Sources/covey/App.swift
git commit -m "feat(covey): Session menu, focus shortcuts, vim-mode stub toggle"
```

---

### Task 4: Manual smoke (Definition of Done, spec §6)

- [ ] **Step 1: Build + full suite** (commands as above).

- [ ] **Step 2: Manual smoke** (performed by the user)

```bash
swift run covey
```

1. View→Show Inspector: панель появляется, ширина драгается, перезапуск
   сохраняет ширину и видимость.
2. ⌘W с выбранной сессией — Kill-шит, окно живо; без выбора — no-op.
3. Session-меню: Kill/Rename открывают шиты; disabled без выбора.
4. ⌘1/⌘2/⌘3 меняют метку фокуса в статус-баре; ⌘3 disabled при скрытом
   инспекторе.
5. Vim Mode переживает перезапуск, ни на что не влияет.

- [ ] **Step 3: Hand off the docs commit to the user**

```bash
git add docs/superpowers/plans/2026-07-02-covey-ui-polish.md
git commit -m "docs: slice 11 implementation plan — UI polish"
```

---

## Definition of Done (from spec §6)

1. Build + full suite green.
2. Smoke items 1–5 above pass.
