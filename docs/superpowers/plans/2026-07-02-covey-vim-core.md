# covey Vim Core (Slice 12) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keyboard-first input: a pure KeyRouter state machine (normal/leader/select/help modes), full List-mode bindings ported from amux-tui, Space leader with a which-key panel, ⌃Q terminal exit, real first-responder routing, ЙЦУКЕН latinization.

**Architecture:** `KeyRouter.route(input:context:) -> KeyAction?` is a pure function (port of TUI `App::handle_key`); `AppModel.apply(_:)` executes actions; a keyDown NSEvent monitor in ContentView feeds the router (skipping text fields and sheets). Terminal focus/scroll commands reach the view through an `onTerminalCommand` callback (the `onTerminalOutput` pattern). Spec: `docs/superpowers/specs/2026-07-02-covey-vim-core-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, `swiftLanguageMode(.v5)`, macOS 26, SwiftUI + Observation, XCTest. No new dependencies.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- ⌃ means macOS **Control** (`NSEvent.ModifierFlags.control`), never ⌘.
- `vimMode` default flips to **true** (`persisted.vimMode ?? true`); the slice-11 test asserting `false` must be updated.
- Unimplemented leader commands stay visible but inert (grey, "later").
- Test run: `swift build --build-tests`, then
  `xcrun xctest -XCTest <Target>.<Class> .build/arm64-apple-macosx/debug/coveyPackageTests.xctest`.
- Full suite: `xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1`.

---

### Task 1: KeyRouter — pure state machine + latinize

**Files:**
- Create: `Sources/covey/KeyRouter.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–3):

```swift
enum InputMode: Equatable { case normal, leader(LeaderMenu), selectSession, help }
enum LeaderMenu: Equatable { case root, git, session, app }
struct KeyInput: Equatable { var char: Character?; var isControl: Bool; var isShift: Bool; var special: Special? }
enum Special: Equatable { case escape, enter, tab, backspace, up, down, left, right, pageUp, pageDown, end }
enum KeyAction: Equatable { /* 20 cases — full definition in Step 1 below */ }
func latinize(_ c: Character) -> Character
enum KeyRouter { static func route(_ input: KeyInput, context: Context) -> KeyAction? }
struct KeyRouter.Context { var mode: InputMode; var focus: AppModel.Focus; var vimMode: Bool; var sheetOpen: Bool }
```

- [ ] **Step 1: Write the compilable skeleton**

`Sources/covey/KeyRouter.swift`:

```swift
import Foundation

enum InputMode: Equatable {
    case normal
    case leader(LeaderMenu)
    case selectSession
    case help
}

enum LeaderMenu: Equatable { case root, git, session, app }

/// Non-character keys the router cares about.
enum Special: Equatable {
    case escape, enter, tab, backspace, up, down, left, right, pageUp, pageDown, end
}

/// Harness-agnostic key event (built from NSEvent in the view layer).
struct KeyInput: Equatable {
    var char: Character?
    var isControl = false
    var isShift = false
    var special: Special?
}

enum KeyAction: Equatable {
    case selectNext, selectPrev, selectFirst
    case enterTerminal
    case exitTerminal
    case toggleTab
    case newSession(prefillDir: Bool)
    case killSelected
    case startFilter
    case openLeader
    case leaderDescend(LeaderMenu)
    case leaderBack
    case closeOverlay
    case renameSelected
    case enterSelectMode
    case selectByNumber(Int)
    case resizeSplit(Int)
    case moveSelected(up: Bool)
    case scrollTerminalPage(up: Bool)
    case scrollTerminalToBottom
    case showHelp
}

/// Map a Cyrillic char to the Latin key at the same physical QWERTY position;
/// non-Cyrillic passes through. Port of amux-core keymap::latinize — vim-style
/// chords keep working on the ЙЦУКЕН layout. Case is preserved.
func latinize(_ c: Character) -> Character {
    c
}

/// Pure key → action mapping; port of amux-tui App::handle_key dispatch.
enum KeyRouter {
    struct Context {
        var mode: InputMode
        var focus: AppModel.Focus
        var vimMode: Bool
        var sheetOpen: Bool
    }

    static func route(_ input: KeyInput, context: Context) -> KeyAction? {
        nil
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoveyAppTests/KeyRouterTests.swift`:

```swift
import XCTest
@testable import covey

final class KeyRouterTests: XCTestCase {
    private func ctx(mode: InputMode = .normal,
                     focus: AppModel.Focus = .sessions,
                     vim: Bool = true,
                     sheet: Bool = false) -> KeyRouter.Context {
        .init(mode: mode, focus: focus, vimMode: vim, sheetOpen: sheet)
    }
    private func key(_ c: Character, ctrl: Bool = false) -> KeyInput {
        .init(char: c, isControl: ctrl)
    }
    private func special(_ s: Special, ctrl: Bool = false) -> KeyInput {
        .init(char: nil, isControl: ctrl, special: s)
    }

    func testLatinize() {
        XCTAssertEqual(latinize("о"), "j")
        XCTAssertEqual(latinize("л"), "k")
        XCTAssertEqual(latinize("П"), "G")
        XCTAssertEqual(latinize("a"), "a")
        XCTAssertEqual(latinize("1"), "1")
    }

    func testNormalModeBindings() {
        let cases: [(KeyInput, KeyAction)] = [
            (key("j"), .selectNext), (key("k"), .selectPrev),
            (special(.down), .selectNext), (special(.up), .selectPrev),
            (key("g"), .selectFirst), (key("G"), .scrollTerminalToBottom),
            (special(.end), .scrollTerminalToBottom),
            (special(.enter), .enterTerminal), (key("o"), .enterTerminal),
            (special(.tab), .toggleTab),
            (key("n"), .newSession(prefillDir: false)),
            (key("N"), .newSession(prefillDir: true)),
            (key("d"), .killSelected),
            (key("/"), .startFilter),
            (key("s"), .enterSelectMode),
            (key(" "), .openLeader),
            (key("K"), .moveSelected(up: true)), (key("J"), .moveSelected(up: false)),
            (key("["), .resizeSplit(-3)), (key("]"), .resizeSplit(3)),
            (key("{"), .resizeSplit(-8)), (key("}"), .resizeSplit(8)),
            (special(.left, ctrl: true), .resizeSplit(-8)),
            (special(.right, ctrl: true), .resizeSplit(8)),
            (key("k", ctrl: true), .scrollTerminalPage(up: true)),
            (key("j", ctrl: true), .scrollTerminalPage(up: false)),
            (special(.pageUp), .scrollTerminalPage(up: true)),
            (special(.pageDown), .scrollTerminalPage(up: false)),
            (key("?"), .showHelp),
        ]
        for (input, want) in cases {
            XCTAssertEqual(KeyRouter.route(input, context: ctx()), want, "\(input)")
        }
        XCTAssertNil(KeyRouter.route(key("z"), context: ctx()), "unbound key ignored")
    }

    func testCyrillicChordsWork() {
        XCTAssertEqual(KeyRouter.route(key("о"), context: ctx()), .selectNext)   // й→...→о = j
        XCTAssertEqual(KeyRouter.route(key("л"), context: ctx()), .selectPrev)   // л = k
    }

    func testTerminalFocusOnlyCtrlQ() {
        let terminal = ctx(focus: .terminal)
        XCTAssertEqual(KeyRouter.route(key("q", ctrl: true), context: terminal), .exitTerminal)
        XCTAssertNil(KeyRouter.route(key("j"), context: terminal))
        XCTAssertNil(KeyRouter.route(key(" "), context: terminal))
        // ⌃Q from the list side does nothing.
        XCTAssertNil(KeyRouter.route(key("q", ctrl: true), context: ctx()))
    }

    func testSheetAndVimOffSwallowEverything() {
        XCTAssertNil(KeyRouter.route(key("j"), context: ctx(sheet: true)))
        XCTAssertNil(KeyRouter.route(key("q", ctrl: true), context: ctx(focus: .terminal, sheet: true)))
        XCTAssertNil(KeyRouter.route(key("j"), context: ctx(vim: false)))
    }

    func testLeaderTree() {
        let root = ctx(mode: .leader(.root))
        XCTAssertEqual(KeyRouter.route(key("g"), context: root), .leaderDescend(.git))
        XCTAssertEqual(KeyRouter.route(key("s"), context: root), .leaderDescend(.session))
        XCTAssertEqual(KeyRouter.route(key("a"), context: root), .leaderDescend(.app))
        XCTAssertEqual(KeyRouter.route(special(.escape), context: root), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(key("x"), context: root), .closeOverlay, "unbound closes")
        let session = ctx(mode: .leader(.session))
        XCTAssertEqual(KeyRouter.route(key("r"), context: session), .renameSelected)
        XCTAssertEqual(KeyRouter.route(special(.backspace), context: session), .leaderBack)
        XCTAssertEqual(KeyRouter.route(key("v"), context: session), .closeOverlay, "later command closes")
        let git = ctx(mode: .leader(.git))
        XCTAssertEqual(KeyRouter.route(key("p"), context: git), .closeOverlay, "later command closes")
    }

    func testSelectSessionMode() {
        let sel = ctx(mode: .selectSession)
        XCTAssertEqual(KeyRouter.route(key("1"), context: sel), .selectByNumber(1))
        XCTAssertEqual(KeyRouter.route(key("9"), context: sel), .selectByNumber(9))
        XCTAssertEqual(KeyRouter.route(special(.escape), context: sel), .closeOverlay)
        XCTAssertNil(KeyRouter.route(key("x"), context: sel), "other keys ignored, mode stays")
    }

    func testHelpClosesOnAnyKey() {
        let help = ctx(mode: .help)
        XCTAssertEqual(KeyRouter.route(key("x"), context: help), .closeOverlay)
        XCTAssertEqual(KeyRouter.route(special(.enter), context: help), .closeOverlay)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests && xcrun xctest -XCTest CoveyAppTests.KeyRouterTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
```

Expected: 8 tests, ≥7 failures (skeleton returns nil / identity latinize).

- [ ] **Step 4: Implement**

Replace `latinize` and `KeyRouter.route`:

```swift
func latinize(_ c: Character) -> Character {
    let cyr = Array("йцукенгшщзхъфывапролджэячсмитьбю")
    let lat = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
    let lower = Character(c.lowercased())
    guard let pos = cyr.firstIndex(of: lower) else { return c }
    let mapped = lat[pos]
    return c.isUppercase ? Character(mapped.uppercased()) : mapped
}
```

```swift
    static func route(_ input: KeyInput, context: Context) -> KeyAction? {
        guard !context.sheetOpen else { return nil }
        let ch = input.char.map(latinize)

        if context.focus == .terminal {
            if input.isControl, ch == "q" { return .exitTerminal }
            return nil
        }
        guard context.vimMode else { return nil }

        switch context.mode {
        case .normal:
            return routeNormal(input, ch)
        case .leader(let menu):
            return routeLeader(menu, input, ch)
        case .selectSession:
            if input.special == .escape { return .closeOverlay }
            if let ch, let n = ch.wholeNumberValue, (1...9).contains(n) {
                return .selectByNumber(n)
            }
            return nil   // anything else is ignored; the mode stays
        case .help:
            return .closeOverlay
        }
    }

    private static func routeNormal(_ input: KeyInput, _ ch: Character?) -> KeyAction? {
        if input.isControl {
            switch input.special {
            case .left: return .resizeSplit(-8)
            case .right: return .resizeSplit(8)
            default: break
            }
            switch ch {
            case "k": return .scrollTerminalPage(up: true)
            case "j": return .scrollTerminalPage(up: false)
            default: return nil
            }
        }
        switch input.special {
        case .down: return .selectNext
        case .up: return .selectPrev
        case .enter: return .enterTerminal
        case .tab: return .toggleTab
        case .pageUp: return .scrollTerminalPage(up: true)
        case .pageDown: return .scrollTerminalPage(up: false)
        case .end: return .scrollTerminalToBottom
        default: break
        }
        switch ch {
        case "j": return .selectNext
        case "k": return .selectPrev
        case "g": return .selectFirst
        case "G": return .scrollTerminalToBottom
        case "o": return .enterTerminal
        case "n": return .newSession(prefillDir: false)
        case "N": return .newSession(prefillDir: true)
        case "d": return .killSelected
        case "/": return .startFilter
        case "s": return .enterSelectMode
        case " ": return .openLeader
        case "K": return .moveSelected(up: true)
        case "J": return .moveSelected(up: false)
        case "[": return .resizeSplit(-3)
        case "]": return .resizeSplit(3)
        case "{": return .resizeSplit(-8)
        case "}": return .resizeSplit(8)
        case "?": return .showHelp
        default: return nil
        }
    }

    private static func routeLeader(_ menu: LeaderMenu, _ input: KeyInput, _ ch: Character?) -> KeyAction? {
        if input.special == .escape { return .closeOverlay }
        if menu != .root, input.special == .backspace { return .leaderBack }
        switch (menu, ch) {
        case (.root, "g"): return .leaderDescend(.git)
        case (.root, "s"): return .leaderDescend(.session)
        case (.root, "a"): return .leaderDescend(.app)
        case (.session, "r"): return .renameSelected
        // Every other command in the tree is a later slice; like the TUI,
        // an unbound key closes the leader.
        default: return .closeOverlay
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Hand off commit to the user**

```bash
git add Sources/covey/KeyRouter.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): KeyRouter — pure vim-mode key state machine"
```

---

### Task 2: AppModel — inputMode, listTab, apply()

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Tests/CoveyAppTests/AppModelChromeTests.swift` (append + fix one assert)

**Interfaces:**
- Consumes: `KeyAction`, `InputMode`, `LeaderMenu` (Task 1).
- Produces (used by Task 3):
  - `enum ListTab { case active, recent }`, `var listTab`, `var recentSelected: Int?`
  - `var inputMode: InputMode`
  - `var newSessionPrefillDir: String?`
  - `enum TerminalCommand { case focus, blur, scrollPage(up: Bool), scrollToBottom }`,
    `var onTerminalCommand: ((TerminalCommand) -> Void)?`
  - `func apply(_ action: KeyAction)`
  - `func visibleSessionNames() -> [String]`

- [ ] **Step 1: Write the failing tests**

Fix the slice-11 default assert in `testInspectorAndVimStatePersistAndLoad`: replace

```swift
        XCTAssertFalse(model.vimMode)
```

with

```swift
        XCTAssertTrue(model.vimMode, "vim mode is on by default since slice 12")
```

and (same test, further down) the persisted-value assertions stay valid because
the test sets `setVimMode(true)` — leave them.

Append to `AppModelChromeTests`:

```swift
    @MainActor
    func testApplyNavigationWalksVisibleSessions() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s3")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 3 }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s2" }
        model.apply(.selectPrev)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectByNumber(3))
        _ = await eventually { model.selected == "s3" }
        model.apply(.selectFirst)
        _ = await eventually { model.selected == "s1" }
        // filter narrows navigation
        model.setFilter("s3")
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s3" }
        model.setFilter("")
        for s in model.sessions { daemon.registry.kill(name: s.name) }
    }

    @MainActor
    func testApplyModeTransitionsAndModals() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openLeader)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.leaderDescend(.session))
        XCTAssertEqual(model.inputMode, .leader(.session))
        model.apply(.leaderBack)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.closeOverlay)
        XCTAssertEqual(model.inputMode, .normal)
        model.apply(.enterSelectMode)
        XCTAssertEqual(model.inputMode, .selectSession)
        model.apply(.closeOverlay)
        model.apply(.showHelp)
        XCTAssertEqual(model.inputMode, .help)
        model.apply(.closeOverlay)
        model.apply(.newSession(prefillDir: false))
        XCTAssertEqual(model.modal, .newSession)
        model.modal = nil
        model.apply(.toggleTab)
        XCTAssertEqual(model.listTab, .recent)
        model.apply(.toggleTab)
        XCTAssertEqual(model.listTab, .active)
        model.apply(.resizeSplit(3))
        XCTAssertEqual(model.splitPct, 41)   // 38 default + 3
    }

    @MainActor
    func testApplyKillRenameNeedSelection() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.killSelected)
        XCTAssertNil(model.modal, "no selection — no kill sheet")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.killSelected)
        XCTAssertEqual(model.modal, .kill(name))
        model.modal = nil
        model.apply(.renameSelected)
        XCTAssertEqual(model.modal, .rename(name))
        model.modal = nil
        await model.kill(name)
    }
```

- [ ] **Step 2: Run to verify it fails to compile**

```bash
swift build --build-tests 2>&1 | grep -E "error:" | head -5
```

- [ ] **Step 3: Implement in AppModel.swift**

1. New types inside the class (next to `Focus`):

```swift
    public enum ListTab: Equatable { case active, recent }

    public enum TerminalCommand: Equatable {
        case focus, blur, scrollPage(up: Bool), scrollToBottom
    }
```

2. State (after `filterFocusTick`):

```swift
    public private(set) var inputMode: InputMode = .normal
    public private(set) var listTab: ListTab = .active
    public private(set) var recentSelected: Int?
    /// Dir to prefill in the New Session sheet (set by `N`).
    public private(set) var newSessionPrefillDir: String?
    /// Commands for the mounted terminal view (focus/scroll); set by the
    /// representable like `onTerminalOutput`.
    public var onTerminalCommand: ((TerminalCommand) -> Void)?
```

3. `vimMode` load in `start()` becomes:

```swift
        vimMode = persisted.vimMode ?? true
```

4. Helpers + `apply` (after the `orderedDirs()` private helper, before `// MARK: - private`):

```swift
    /// Flat visible ordering: orderedSessions() narrowed by the fuzzy filter.
    public func visibleSessionNames() -> [String] {
        orderedSessions().flatMap { group in
            group.sessions.map(\.name).filter { fuzzyMatch(filter, $0) }
        }
    }

    /// Recents hidden while a live session reuses the name (Recent tab rule).
    public func visibleRecents() -> [RecentSession] {
        let active = Set(sessions.map(\.name))
        return recents.filter { !active.contains($0.name) }
    }

    public func setListTab(_ tab: ListTab) {
        listTab = tab
        recentSelected = tab == .recent ? (visibleRecents().isEmpty ? nil : 0) : nil
    }

    public func clearNewSessionPrefill() { newSessionPrefillDir = nil }

    // swiftlint:disable:next cyclomatic_complexity
    public func apply(_ action: KeyAction) {
        switch action {
        case .selectNext: step(by: 1)
        case .selectPrev: step(by: -1)
        case .selectFirst: jump(to: 0)
        case .selectByNumber(let n):
            jump(to: n - 1)
            inputMode = .normal
        case .enterTerminal:
            if listTab == .recent {
                let items = visibleRecents()
                if let idx = recentSelected, idx < items.count {
                    let r = items[idx]
                    Task { await relaunchRecent(r) }
                }
            } else if selected != nil {
                setFocus(.terminal)
                onTerminalCommand?(.focus)
            }
        case .exitTerminal:
            setFocus(.sessions)
            onTerminalCommand?(.blur)
        case .toggleTab:
            setListTab(listTab == .active ? .recent : .active)
        case .newSession(let prefill):
            newSessionPrefillDir = prefill
                ? sessions.first(where: { $0.name == selected })?.dir : nil
            modal = .newSession
        case .killSelected:
            if let selected { modal = .kill(selected) }
        case .renameSelected:
            inputMode = .normal
            if let selected { modal = .rename(selected) }
        case .startFilter:
            requestFilterFocus()
        case .openLeader:
            inputMode = .leader(.root)
        case .leaderDescend(let menu):
            inputMode = .leader(menu)
        case .leaderBack:
            inputMode = .leader(.root)
        case .closeOverlay:
            inputMode = .normal
        case .enterSelectMode:
            inputMode = .selectSession
        case .resizeSplit(let delta):
            setSplitPct(splitPct + delta)
        case .moveSelected(let up):
            moveSelectedSession(up: up)
        case .scrollTerminalPage(let up):
            onTerminalCommand?(.scrollPage(up: up))
        case .scrollTerminalToBottom:
            onTerminalCommand?(.scrollToBottom)
        case .showHelp:
            inputMode = .help
        }
    }

    private func step(by delta: Int) {
        if listTab == .recent {
            let count = visibleRecents().count
            guard count > 0 else { recentSelected = nil; return }
            let cur = recentSelected ?? -1
            recentSelected = min(count - 1, max(0, cur + delta))
            return
        }
        let names = visibleSessionNames()
        guard !names.isEmpty else { return }
        let cur = selected.flatMap { names.firstIndex(of: $0) } ?? -1
        let next = min(names.count - 1, max(0, cur + delta))
        let name = names[next]
        Task { await select(name) }
    }

    private func jump(to index: Int) {
        if listTab == .recent {
            let count = visibleRecents().count
            guard count > 0 else { return }
            recentSelected = min(count - 1, max(0, index))
            return
        }
        let names = visibleSessionNames()
        guard !names.isEmpty else { return }
        let name = names[min(names.count - 1, max(0, index))]
        Task { await select(name) }
    }

    /// Keyboard reorder within the selected session's project group.
    private func moveSelectedSession(up: Bool) {
        guard listTab == .active, let selected else { return }
        guard let group = orderedSessions().first(where: { g in
            g.sessions.contains { $0.name == selected }
        }) else { return }
        let names = group.sessions.map(\.name)
        guard let idx = names.firstIndex(of: selected) else { return }
        let to = up ? idx - 1 : idx + 2   // IndexSet move semantics
        guard up ? idx > 0 : idx < names.count - 1 else { return }
        moveSession(inDir: group.dir, from: IndexSet(integer: idx), to: max(0, to))
    }
```

Note `step`/`jump` hop through `Task { await select(name) }` — tests use
`eventually`.

- [ ] **Step 4: Run tests + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest -XCTest CoveyAppTests.AppModelChromeTests .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed" | tail -1
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: chrome tests green (incl. fixed vim default), full suite 0 failures.

- [ ] **Step 5: Hand off commit to the user**

```bash
git add Sources/covey/AppModel.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): AppModel input modes + apply(KeyAction), vim on by default"
```

---

### Task 3: Wiring — monitor, first responder, tabs, which-key, help, hints

**Files:**
- Modify: `Sources/covey/Views/ContentView.swift` (monitor + overlays)
- Modify: `Sources/covey/TerminalController.swift` (onTerminalCommand)
- Modify: `Sources/covey/Views/SessionListView.swift` (model-driven tab, recent selection, filter Esc)
- Modify: `Sources/covey/Views/Sheets.swift` (NewSessionSheet dir prefill)
- Modify: `Sources/covey/Views/StatusBar.swift` (mode indicator + hints)
- Create: `Sources/covey/Views/WhichKeyView.swift`
- Create: `Sources/covey/Views/HelpOverlay.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–2.

- [ ] **Step 1: KeyInput from NSEvent + monitor rewrite (ContentView)**

Add a fileprivate builder and replace the ⌘W-only monitor closure:

```swift
private func keyInput(from event: NSEvent) -> KeyInput {
    let specials: [UInt16: Special] = [
        53: .escape, 36: .enter, 48: .tab, 51: .backspace,
        126: .up, 125: .down, 123: .left, 124: .right,
        116: .pageUp, 121: .pageDown, 119: .end,
    ]
    let flags = event.modifierFlags
    return KeyInput(
        char: event.charactersIgnoringModifiers?.first,
        isControl: flags.contains(.control),
        isShift: flags.contains(.shift),
        special: specials[event.keyCode]
    )
}
```

Monitor closure body becomes:

```swift
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ⌘W: kill sheet for the selected session (File→Close would win otherwise).
                if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                   event.charactersIgnoringModifiers == "w" {
                    guard model.modal == nil, let selected = model.selected else { return event }
                    model.modal = .kill(selected)
                    return nil
                }
                // ⌘-anything else belongs to the menu system.
                guard !event.modifierFlags.contains(.command) else { return event }
                // While a text field edits (filter, sheets), keys are its own.
                if let responder = event.window?.firstResponder, responder is NSTextView {
                    return event
                }
                let context = KeyRouter.Context(mode: model.inputMode,
                                                focus: model.focus,
                                                vimMode: model.vimMode,
                                                sheetOpen: model.modal != nil)
                guard let action = KeyRouter.route(keyInput(from: event), context: context) else {
                    return event
                }
                model.apply(action)
                return nil
            }
```

- [ ] **Step 2: Overlays in ContentView body**

After `.overlay(alignment: .bottom) { toastBar }` add:

```swift
        .overlay(alignment: .bottom) {
            if case .leader(let menu) = model.inputMode {
                WhichKeyView(menu: menu).padding(.bottom, 36)
            }
        }
        .overlay {
            if model.inputMode == .help { HelpOverlay() }
        }
```

- [ ] **Step 3: onTerminalCommand in TerminalController**

In `makeNSView`, after the `onBufferSwitch` assignment:

```swift
        model.onTerminalCommand = { [weak view] command in
            guard let view else { return }
            switch command {
            case .focus:
                view.window?.makeFirstResponder(view)
            case .blur:
                view.window?.makeFirstResponder(nil)
            case .scrollPage(let up):
                if up { view.scrollUp(lines: 10) } else { view.scrollDown(lines: 10) }
            case .scrollToBottom:
                view.scroll(toPosition: 1.0)
            }
        }
```

- [ ] **Step 4: SessionListView — model tab, recent selection, filter Esc**

1. Delete the local `@State private var tab` and `enum Tab`; drive the picker
   from the model:

```swift
            Picker("", selection: Binding(
                get: { model.listTab },
                set: { model.setListTab($0) })) {
                Text("Active").tag(AppModel.ListTab.active)
                Text("Recent").tag(AppModel.ListTab.recent)
            }
```

and switch the two `if tab == .active` sites to `model.listTab == .active`.

2. Filter field gains Esc handling (after `.onChange(...)`):

```swift
                    .onExitCommand {
                        model.setFilter("")
                        filterFocused = false
                    }
```

3. Recent rows: highlight the keyboard selection and select on click. Replace
   the `recentList` `ForEach` row content wrapper:

```swift
    private var recentList: some View {
        let items = model.visibleRecents()
        return List {
            ForEach(Array(items.enumerated()), id: \.element.name) { idx, r in
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
                .listRowBackground(model.recentSelected == idx
                                   ? Color.accentColor.opacity(0.15) : nil)
            }
        }
    }
```

(The old local `active`-set filtering moves into `model.visibleRecents()`.)

4. NewSessionSheet prefill (in `Sources/covey/Views/Sheets.swift`): add to
   `NewSessionSheet.body`'s outer `VStack`:

```swift
        .onAppear {
            if let prefill = model.newSessionPrefillDir { dir = prefill }
            model.clearNewSessionPrefill()
        }
```

- [ ] **Step 5: WhichKeyView**

`Sources/covey/Views/WhichKeyView.swift` — the leader tree verbatim from
`amux-tui/ui/leader.rs`; implemented commands bright, later ones dim:

```swift
import SwiftUI

/// Which-key panel for the Space leader (port of amux-tui ui/leader.rs).
struct WhichKeyView: View {
    let menu: LeaderMenu

    private struct Row: Identifiable {
        let id = UUID()
        let key: String
        let label: String
        let implemented: Bool
    }

    private var rows: [Row] {
        switch menu {
        case .root: return [
            Row(key: "g", label: "git — issue · promote · delete branch · cleanup", implemented: true),
            Row(key: "s", label: "session — rename · verify · nvim", implemented: true),
            Row(key: "a", label: "app — usage log · restart claude", implemented: true),
        ]
        case .git: return [
            Row(key: "i", label: "create github issue (later)", implemented: false),
            Row(key: "p", label: "promote worktree to root (later)", implemented: false),
            Row(key: "b", label: "delete session branch (later)", implemented: false),
            Row(key: "c", label: "cleanup merged branches (later)", implemented: false),
        ]
        case .session: return [
            Row(key: "r", label: "rename session", implemented: true),
            Row(key: "R", label: "rename project (later)", implemented: false),
            Row(key: "v", label: "verify / cancel (later)", implemented: false),
            Row(key: "V", label: "verification details (later)", implemented: false),
            Row(key: "e", label: "nvim in agent dir (later)", implemented: false),
        ]
        case .app: return [
            Row(key: "l", label: "usage log (later)", implemented: false),
            Row(key: "u", label: "restart all claude sessions (later)", implemented: false),
        ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.key).fontWeight(.bold).monospaced()
                        .frame(width: 16, alignment: .leading)
                    Text(row.label)
                }
                .font(.callout)
                .foregroundStyle(row.implemented ? .primary : .tertiary)
            }
            Text(menu == .root ? "esc close" : "backspace back · esc close")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8)
    }

    private var title: String {
        switch menu {
        case .root: return "space —"
        case .git: return "space g — git"
        case .session: return "space s — session"
        case .app: return "space a — app"
        }
    }
}
```

- [ ] **Step 6: HelpOverlay**

`Sources/covey/Views/HelpOverlay.swift` — one static page, closes via any key
(router) or click:

```swift
import SwiftUI

/// Keyboard reference (port of amux-tui modal_help, keys tab only).
struct HelpOverlay: View {
    private let groups: [(String, [(String, String)])] = [
        ("navigate", [
            ("j / k", "next / previous session"),
            ("g", "first session"),
            ("s then 1-9", "jump to visible session"),
            ("tab", "active / recent tab"),
            ("/", "filter sessions"),
        ]),
        ("act", [
            ("enter / o", "focus terminal (recent: relaunch)"),
            ("⌃q", "leave terminal back to the list"),
            ("n / N", "new session (N: same project)"),
            ("d", "kill session"),
            ("K / J", "move session up / down"),
        ]),
        ("view", [
            ("[ ] { }", "resize split"),
            ("⌃k / ⌃j", "scroll terminal page up / down"),
            ("G / end", "terminal to bottom"),
        ]),
        ("leader (space)", [
            ("g", "git: issue · promote · delete branch · cleanup (later)"),
            ("s", "session: rename · verify (later) · nvim (later)"),
            ("a", "app: usage log · restart claude (later)"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keys").font(.headline)
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.0).font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(group.1, id: \.0) { key, label in
                        HStack(spacing: 10) {
                            Text(key).monospaced().fontWeight(.bold)
                                .frame(width: 90, alignment: .leading)
                            Text(label).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            Text("any key closes").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
    }
}
```

- [ ] **Step 7: StatusBar hints + mode indicator**

Replace the leading hint `Text` and add the mode chip:

```swift
        HStack(spacing: 12) {
            Text(hints).foregroundStyle(.secondary).font(.caption)
            Spacer()
            if model.vimMode {
                Text(modeLabel).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            if model.historyMode {
                Text("HISTORY").foregroundStyle(.yellow).font(.caption).fontWeight(.semibold)
            }
            Text(focusLabel)
                .foregroundStyle(.secondary).font(.caption)
        }
```

with the two computed properties:

```swift
    private var hints: String {
        if model.focus == .terminal { return "⌃q back to list" }
        switch model.inputMode {
        case .leader: return "esc close · backspace back"
        case .selectSession: return "1-9 jump · esc cancel"
        case .help: return "any key closes"
        case .normal:
            return model.vimMode
                ? "n new · enter attach · d kill · space menu · / filter · ? help"
                : "⌘N new · ⌘F filter"
        }
    }

    private var modeLabel: String {
        switch model.inputMode {
        case .normal: return model.focus == .terminal ? "TERM" : "NORMAL"
        case .leader: return "LEADER"
        case .selectSession: return "SELECT"
        case .help: return "HELP"
        }
    }
```

(The old hardcoded `Text("⌘N new · ⌘F filter")` is removed.)

- [ ] **Step 8: Build + full suite**

```bash
swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -2
xcrun xctest .build/arm64-apple-macosx/debug/coveyPackageTests.xctest 2>&1 | grep -E "Executed .* tests," | tail -1
```

Expected: `Build complete!`, 0 failures.

- [ ] **Step 9: Hand off commit to the user**

```bash
git add Sources/covey/Views/ContentView.swift Sources/covey/TerminalController.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/StatusBar.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/WhichKeyView.swift Sources/covey/Views/HelpOverlay.swift
git commit -m "feat(covey): vim-mode wiring — key monitor, which-key, help, hints"
```

---

### Task 4: Manual smoke (Definition of Done, spec §9) — by the user

```bash
swift run covey
```

Checklist per spec §9 item 2 (keyboard only), plus docs commit:

```bash
git add docs/superpowers/plans/2026-07-02-covey-vim-core.md
git commit -m "docs: slice 12 implementation plan — vim core"
```

---

## Definition of Done (from spec §9)

1. Build + full suite green (KeyRouter + chrome additions).
2. Keyboard-only smoke passes (nav, ⌃Q, leader, select, resize, reorder, scroll, help, ЙЦУКЕН, vim-off fallback).
3. Status bar mode/hints track the input mode.
