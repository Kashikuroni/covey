# covey Chrome + Ayu (Slice 20) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ayu palette (Mirage/Light) across the whole app including the terminal, title-bar-level topbar without the view switcher, no `+` toolbar button, Recent as a tab inside the new-session sheet, and a footer filter driven by `/`.

**Architecture:** `Tokens` keeps its structure — only values change (plus a new `accent`), so every tokenized view recolors itself; the root gets `.tint(accent)`. `Theme` grows a 16-color ANSI array applied via SwiftTerm's `installColors`. The window switches to `.hiddenTitleBar` (kills the toolbar and the `+` button, puts TopBar content at traffic-light level). `ListTab`/Recent plumbing moves out of the main window into a `New | Recent` segment in NewSessionSheet. The always-visible filter field is replaced by `filterActive` state rendered inside StatusBar. Spec: `docs/superpowers/specs/2026-07-04-covey-chrome-ayu-design.md`.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, SwiftTerm (`installColors(_ colors: [SwiftTerm.Color])` — 16 entries or no-op), XCTest.

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; each task ends with the exact command.
- Color values are the LITERALS from `ayu-theme/ayu-colors/themes/{mirage,light}.yaml` as tabulated in the spec — no invented colors.
- Git view / git buttons in chrome: not in this slice. Inspector, notes, sheet layouts (beyond the Recent tab): untouched.
- Test runs: `swift test --filter <ClassName>`; full suite: `swift test`.

---

### Task 1: Ayu values in Tokens + accent + root tint

**Files:**
- Modify: `Sources/covey/Tokens.swift` (values + `accent`)
- Modify: `Sources/covey/Views/ContentView.swift` (root `.tint`)
- Test: `Tests/CoveyAppTests/TokensTests.swift`

**Interfaces:**
- Produces: `Tokens.accent: Color` (used by Task 3's TopBar and anything accent-tinted).

- [ ] **Step 1: Failing tests** — replace the three test bodies in `Tests/CoveyAppTests/TokensTests.swift`:

```swift
    func testDarkPortMatchesAyuMirage() {
        XCTAssertEqual(Tokens.dark.bg, Color(hex: 0x181C26))
        XCTAssertEqual(Tokens.dark.surface, Color(hex: 0x1F2430))
        XCTAssertEqual(Tokens.dark.card, Color(hex: 0x242936))
        XCTAssertEqual(Tokens.dark.t1, Color(hex: 0xCCCAC2))
        XCTAssertEqual(Tokens.dark.run, Color(hex: 0xFFA659))
        XCTAssertEqual(Tokens.dark.wait, Color(hex: 0xFFCD66))
        XCTAssertEqual(Tokens.dark.accent, Color(hex: 0xFFCC66))
    }

    func testLightPortMatchesAyuLight() {
        XCTAssertEqual(Tokens.light.bg, Color(hex: 0xEBEEF0))
        XCTAssertEqual(Tokens.light.card, Color(hex: 0xFCFCFC))
        XCTAssertEqual(Tokens.light.run, Color(hex: 0xFA8532))
        XCTAssertEqual(Tokens.light.accent, Color(hex: 0xF29718))
    }

    func testThemeSelectionAndConstants() {
        XCTAssertEqual(Tokens(Theme(raw: "dark")).bg, Tokens.dark.bg)
        XCTAssertEqual(Tokens(Theme(raw: "light")).bg, Tokens.light.bg)
        XCTAssertEqual(Tokens.r, 6)
        XCTAssertEqual(Tokens.rSm, 4)
        XCTAssertEqual(Tokens.rLg, 10)
    }
```

Run: `swift test --filter TokensTests`
Expected: FAIL (old amux values, no `accent`).

- [ ] **Step 2: New values** — in `Sources/covey/Tokens.swift`: add `let accent: Color` to the stored properties (after `shadowColor`), add `accent:` to the private init, and replace both static instances:

```swift
    static let dark = Tokens(
        bg: Color(hex: 0x181C26), surface: Color(hex: 0x1F2430),
        surf2: Color(hex: 0x242936), surf3: Color(hex: 0x282E3B),
        surf4: Color(hex: 0x6E7C8F).opacity(0.4),
        card: Color(hex: 0x242936), cardHover: Color(hex: 0x282E3B),
        termBg: Color(hex: 0x242936),
        bd: Color(hex: 0x171B24),
        bd2: Color(hex: 0x6E7C8F).opacity(0.25),
        bd3: Color(hex: 0x6E7C8F).opacity(0.45),
        t1: Color(hex: 0xCCCAC2), t2: Color(hex: 0xCCCAC2).opacity(0.8),
        t3: Color(hex: 0x707A8C), t4: Color(hex: 0x707A8C).opacity(0.6),
        run: Color(hex: 0xFFA659), wait: Color(hex: 0xFFCD66),
        idle: Color(hex: 0x282E3B), ok: Color(hex: 0x87D96C),
        err: Color(hex: 0xF27983), warn: Color(hex: 0xD9BE98),
        diffAdd: Color(hex: 0x87D96C), diffDel: Color(hex: 0xF27983),
        shadowColor: Color.black.opacity(0.2),
        accent: Color(hex: 0xFFCC66))

    static let light = Tokens(
        bg: Color(hex: 0xEBEEF0), surface: Color(hex: 0xF8F9FA),
        surf2: Color(hex: 0xFCFCFC), surf3: Color(hex: 0xFFFFFF),
        surf4: Color(hex: 0xADAEB1).opacity(0.5),
        card: Color(hex: 0xFCFCFC), cardHover: Color(hex: 0xFFFFFF),
        termBg: Color(hex: 0xFCFCFC),
        bd: Color(hex: 0x6B7D8F).opacity(0.12),
        bd2: Color(hex: 0x6B7D8F).opacity(0.20),
        bd3: Color(hex: 0x6B7D8F).opacity(0.32),
        t1: Color(hex: 0x5C6166), t2: Color(hex: 0x787B80),
        t3: Color(hex: 0x828E9F), t4: Color(hex: 0xABB2BD),
        run: Color(hex: 0xFA8532), wait: Color(hex: 0xEBA400),
        idle: Color(hex: 0xCED4DA), ok: Color(hex: 0x6CBF43),
        err: Color(hex: 0xFF7383), warn: Color(hex: 0xE59645),
        diffAdd: Color(hex: 0x6CBF43), diffDel: Color(hex: 0xFF7383),
        shadowColor: Color(hex: 0x6B7D8F).opacity(0.1),
        accent: Color(hex: 0xF29718))
```

The header comment of the file changes to name ayu as the source:

```swift
/// The design system on the ayu palette (dark = ayu Mirage, light = ayu
/// Light; literals from ayu-theme/ayu-colors). Single color source for the
/// SwiftUI layer; the terminal palette lives in Theme.swift.
```

- [ ] **Step 3: Root tint** — in `Sources/covey/Views/ContentView.swift`, next to the `.preferredColorScheme` modifier on the root view, add:

```swift
        .tint(Tokens(Theme(raw: model.themeRaw)).accent)
```

- [ ] **Step 4: Green + full suite**

Run: `swift test --filter TokensTests && swift test`
Expected: PASS.

- [ ] **Step 5: Hand the commit to the user**

```bash
git add Sources/covey/Tokens.swift Sources/covey/Views/ContentView.swift Tests/CoveyAppTests/TokensTests.swift
git commit -m "feat(covey): ayu palette in design tokens + accent tint"
```

---

### Task 2: Terminal on ayu — Theme.ansi + installColors

**Files:**
- Modify: `Sources/covey/Theme.swift`
- Modify: `Sources/covey/TerminalController.swift:46-51` (applyTheme)
- Test: `Tests/CoveyAppTests/ThemeTests.swift` (new)

**Interfaces:**
- Produces: `Theme.ansi: [NSColor]` (exactly 16), updated `background`/`foreground`/`cursor`.

- [ ] **Step 1: Failing tests** — create `Tests/CoveyAppTests/ThemeTests.swift`:

```swift
import XCTest
import AppKit
@testable import covey

final class ThemeTests: XCTestCase {
    func testAnsiHasSixteenColors() {
        XCTAssertEqual(Theme.dark.ansi.count, 16)
        XCTAssertEqual(Theme.light.ansi.count, 16)
    }

    func testAyuSpotChecks() {
        // mirage: red #F28779 at index 1, brightWhite #FFFFFF at 15
        XCTAssertEqual(Theme.dark.ansi[1], NSColor(hex: 0xF28779))
        XCTAssertEqual(Theme.dark.ansi[15], NSColor(hex: 0xFFFFFF))
        // light: green #86B300 at index 2
        XCTAssertEqual(Theme.light.ansi[2], NSColor(hex: 0x86B300))
    }
}
```

Run: `swift test --filter ThemeTests`
Expected: FAIL — `ansi`/`NSColor(hex:)` undefined.

- [ ] **Step 2: Implement** — replace `Sources/covey/Theme.swift` with:

```swift
import AppKit

enum Theme: String {
    case dark, light

    init(raw: String) { self = Theme(rawValue: raw) ?? .dark }

    /// ayu editor.bg: Mirage lift / Light lift.
    var background: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0x242936)
        case .light: return NSColor(hex: 0xFCFCFC)
        }
    }
    /// ayu editor.fg.
    var foreground: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0xCCCAC2)
        case .light: return NSColor(hex: 0x5C6166)
        }
    }
    /// ayu common.accent.
    var cursor: NSColor {
        switch self {
        case .dark:  return NSColor(hex: 0xFFCC66)
        case .light: return NSColor(hex: 0xF29718)
        }
    }

    /// The 16 ANSI colors (ayu terminal sections; computed yaml values are
    /// replaced by the nearest literal of the same theme).
    var ansi: [NSColor] {
        switch self {
        case .dark: return [
            NSColor(hex: 0x0A0000), NSColor(hex: 0xF28779),   // black red
            NSColor(hex: 0xD5FF80), NSColor(hex: 0xFFCD66),   // green yellow
            NSColor(hex: 0x73D0FF), NSColor(hex: 0xDFBFFF),   // blue magenta
            NSColor(hex: 0x95E6CB), NSColor(hex: 0xCCCAC2),   // cyan white
            NSColor(hex: 0x6E7C8F), NSColor(hex: 0xF28779),   // brBlack brRed
            NSColor(hex: 0xD5FF80), NSColor(hex: 0xFFCD66),
            NSColor(hex: 0x73D0FF), NSColor(hex: 0xDFBFFF),
            NSColor(hex: 0x95E6CB), NSColor(hex: 0xFFFFFF),
        ]
        case .light: return [
            NSColor(hex: 0x5C6166), NSColor(hex: 0xF07171),
            NSColor(hex: 0x86B300), NSColor(hex: 0xEBA400),
            NSColor(hex: 0x22A4E6), NSColor(hex: 0xA37ACC),
            NSColor(hex: 0x4CBF99), NSColor(hex: 0xADAEB1),
            NSColor(hex: 0x828E9F), NSColor(hex: 0xF07171),
            NSColor(hex: 0x86B300), NSColor(hex: 0xEBA400),
            NSColor(hex: 0x22A4E6), NSColor(hex: 0xA37ACC),
            NSColor(hex: 0x4CBF99), NSColor(hex: 0xFFFFFF),
        ]
        }
    }
}

extension NSColor {
    /// Opaque sRGB color from 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
```

- [ ] **Step 3: applyTheme installs the palette** — in `Sources/covey/TerminalController.swift` replace `applyTheme`:

```swift
    private func applyTheme(to view: TerminalView) {
        let theme = Theme(raw: model.themeRaw)
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.cursor
        // 16 ANSI colors; SwiftTerm expects its own Color type (16-bit channels).
        view.installColors(theme.ansi.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535),
                                   green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
    }
```

- [ ] **Step 4: Green + full suite**

Run: `swift test --filter ThemeTests && swift test`
Expected: PASS.

- [ ] **Step 5: Hand the commit to the user**

```bash
git add Sources/covey/Theme.swift Sources/covey/TerminalController.swift Tests/CoveyAppTests/ThemeTests.swift
git commit -m "feat(covey): ayu terminal palette — ANSI-16 via installColors"
```

---

### Task 3: hidden title bar, topbar at traffic-light level, no `+`

**Files:**
- Modify: `Sources/covey/App.swift` (windowStyle)
- Modify: `Sources/covey/Views/TopBar.swift` (rework)
- Modify: `Sources/covey/Views/SessionListView.swift` (drop `.toolbar`)

**Interfaces:**
- Consumes: `Tokens.accent` etc. (Task 1).

- [ ] **Step 1: Window style** — in `Sources/covey/App.swift`, on the `WindowGroup` (after its closing brace, next to `.commands`):

```swift
        .windowStyle(.hiddenTitleBar)
```

- [ ] **Step 2: TopBar rework** — replace `Sources/covey/Views/TopBar.swift` content of `body` (drop `ViewKind`, the `@State view`, the Picker):

```swift
struct TopBar: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        HStack(spacing: 12) {
            Text("covey").fontWeight(.semibold).foregroundStyle(tk.t1)
            let c = model.counts
            Text("\(c.total) · ▶\(c.running) · ⏸\(c.waiting)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tk.t3)
            Spacer()
            Button {
                model.setTheme(model.themeRaw == "dark" ? "light" : "dark")
            } label: {
                Image(systemName: model.themeRaw == "dark" ? "sun.max" : "moon")
            }
            .buttonStyle(.borderless).help("Toggle theme")
            TimelineView(.everyMinute) { ctx in
                Text(clock(ctx.date))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tk.t3)
            }
        }
        // Room for the traffic lights overlaid by the hidden title bar.
        .padding(.leading, 78).padding(.trailing, 14)
        .frame(height: 38)
        .background(tk.surface)
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
```

- [ ] **Step 3: Drop the `+` toolbar** — in `Sources/covey/Views/SessionListView.swift` delete:

```swift
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
```

- [ ] **Step 4: Build + suite + eyeball**

Run: `swift build && swift test`
Expected: green. `swift run covey`: traffic lights sit ON the bar row; no `+`; no Standard/Git.

- [ ] **Step 5: Hand the commit to the user**

```bash
git add Sources/covey/App.swift Sources/covey/Views/TopBar.swift Sources/covey/Views/SessionListView.swift
git commit -m "feat(covey): title-bar-level topbar, drop view switcher and + button"
```

---

### Task 4: Recent moves into NewSessionSheet

**Files:**
- Modify: `Sources/covey/AppModel.swift` (delete ListTab plumbing)
- Modify: `Sources/covey/KeyRouter.swift:30,159` (+ delete `toggleTab`)
- Modify: `Sources/covey/Views/SessionListView.swift` (drop Picker + recentList)
- Modify: `Sources/covey/Views/NewSessionSheet.swift` (New | Recent segment)
- Modify: `Sources/covey/Views/HelpOverlay.swift:10`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift:33,155`

**Interfaces:**
- Consumes: `model.visibleRecents()`, `model.relaunchRecent(_:)`, `humanizeAge`, `Tokens` — all existing.

- [ ] **Step 1: Failing router tests** — in `Tests/CoveyAppTests/KeyRouterTests.swift`:
  - line 33: delete the `(special(.tab), .toggleTab),` entry;
  - line 155: replace `XCTAssertEqual(KeyRouter.route(special(.tab), context: ctx()), .toggleTab)` with `XCTAssertNil(KeyRouter.route(special(.tab), context: ctx()), "plain tab is unbound now")`.

Run: `swift test --filter KeyRouterTests`
Expected: still compiles (toggleTab exists) but the nil assertion FAILS.

- [ ] **Step 2: Router** — `Sources/covey/KeyRouter.swift`: delete `case toggleTab` (line 30); line 159 becomes:

```swift
        case .tab: return input.isShift ? .sendShiftTab : nil
```

- [ ] **Step 3: AppModel cleanup** — delete: `enum ListTab` + `listTab` + `recentSelected` properties, `setListTab`, the `.toggleTab` apply-case, and the `listTab == .recent` branches in `.enterTerminal` (`AppModel.swift:455-461` — keep the plain `selected != nil` path), `step(by:)` (`:662-667`) and `jump(to:)` (`:677-682`). `visibleRecents`/`relaunchRecent`/`recents` stay.

- [ ] **Step 4: SessionListView cleanup** — delete the tab `Picker` (body lines 10-18), the `if model.listTab == .active` conditions (the filter TextField block stays until Task 5 — just drop the tab condition around it), and the whole `recentList` property; `body` shows `activeList` directly.

- [ ] **Step 5: NewSessionSheet Recent tab** — in `Sources/covey/Views/NewSessionSheet.swift`:

Add state and a tab enum at the top of the struct:

```swift
    enum SheetTab { case new, recent }
    @State private var sheetTab: SheetTab = .new
    @State private var recentIdx = 0
    @FocusState private var recentFocused: Bool
```

Wrap the existing form: `body`'s `VStack` begins with the segment, then branches:

```swift
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $sheetTab) {
                Text("New").tag(SheetTab.new)
                Text("Recent").tag(SheetTab.recent)
            }
            .pickerStyle(.segmented).labelsHidden()
            if sheetTab == .new {
                newForm
            } else {
                recentTab
            }
        }
```

and focus the list when the tab opens (next to the sheet's other `.onChange` modifiers):

```swift
        .onChange(of: sheetTab) { _, tab in
            if tab == .recent { recentIdx = 0; recentFocused = true }
        }
```

(the current content of `body`'s VStack — from `Text("New session")` through the bottom HStack — moves into a `private var newForm: some View { VStack(alignment: .leading, spacing: 10) { … } }`; all `.onKeyPress`/`.onExitCommand`/`.onAppear`/`.task`/`.onChange` modifiers stay attached to the OUTER VStack as they are now).

Add the recent tab view:

```swift
    private var recentTab: some View {
        let items = model.visibleRecents()
        let now = Int64(Date().timeIntervalSince1970)
        let tk = Tokens(Theme(raw: model.themeRaw))
        return Group {
            if items.isEmpty {
                Text("no recently-stopped sessions")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.name) { idx, r in
                        HStack(spacing: 7) {
                            Text("↻").font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(r.resumeCmd != nil ? tk.t4 : tk.surf4)
                            Text(r.name).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(tk.t2).lineLimit(1)
                            Text(String(r.agent.split(separator: " ").first ?? ""))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tk.t4)
                            Text(collapseHome(r.dir))
                                .font(.system(size: 11)).foregroundStyle(tk.t4)
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            if let stopped = r.stoppedAt {
                                Text(humanizeAge(now - stopped))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(tk.t4)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(idx == recentIdx ? tk.surf2 : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Tokens.rSm))
                        .contentShape(Rectangle())
                        .onTapGesture { relaunch(items[idx]) }
                    }
                }
                .focusable()
                .focused($recentFocused)
                .onKeyPress(.downArrow) {
                    recentIdx = min(items.count - 1, recentIdx + 1); return .handled
                }
                .onKeyPress(.upArrow) {
                    recentIdx = max(0, recentIdx - 1); return .handled
                }
                .onKeyPress(.return) {
                    if items.indices.contains(recentIdx) { relaunch(items[recentIdx]) }
                    return .handled
                }
            }
        }
    }

    private func relaunch(_ r: RecentSession) {
        Task {
            await model.relaunchRecent(r)
            model.modal = nil
        }
    }
```

- [ ] **Step 6: HelpOverlay** — delete the `("tab", "active / recent tab"),` line (`HelpOverlay.swift:10`).

- [ ] **Step 7: Green + full suite**

Run: `swift test --filter KeyRouterTests && swift test`
Expected: PASS (AppModel chrome tests touching listTab were removed with the branches — if any test still references `listTab`/`toggleTab`/`recentSelected`, delete that test case; they are covered by the sheet smoke now).

- [ ] **Step 8: Hand the commit to the user**

```bash
git add Sources/covey/AppModel.swift Sources/covey/KeyRouter.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/NewSessionSheet.swift Sources/covey/Views/HelpOverlay.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): recent tab lives in the new-session sheet"
```

---

### Task 5: footer filter on `/`

**Files:**
- Modify: `Sources/covey/AppModel.swift` (filterActive + commit/escape; drop filterFocusTick)
- Modify: `Sources/covey/Views/StatusBar.swift` (filter row)
- Modify: `Sources/covey/Views/SessionListView.swift` (drop the filter TextField)
- Modify: `Sources/covey/App.swift` (⌘F command)
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Produces:

```swift
// AppModel
public private(set) var filterActive: Bool
public func filterEscape()   // clear + deactivate
public func filterCommit()   // clear + deactivate + focus terminal (if selection)
```

- [ ] **Step 1: Failing test** — append to `Tests/CoveyAppTests/AppModelChromeTests.swift` (uses the file's existing `makeModel`/`TestDaemon` helpers):

```swift
    @MainActor
    func testSlashActivatesFooterFilterAndEscapeClears() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertFalse(model.filterActive)
        model.apply(.startFilter)
        XCTAssertTrue(model.filterActive)
        model.setFilter("abc")
        model.filterEscape()
        XCTAssertFalse(model.filterActive)
        XCTAssertEqual(model.filter, "")
    }
```

Run: `swift test --filter AppModelChromeTests.testSlashActivatesFooterFilterAndEscapeClears`
Expected: FAIL — `filterActive` undefined.

- [ ] **Step 2: AppModel** — replace `filterFocusTick`/`requestFilterFocus` (`:67`, `:323`) with:

```swift
    public private(set) var filterActive = false
```

```swift
    /// Esc in the footer filter: clear and give the list back its keys.
    public func filterEscape() {
        filter = ""
        filterActive = false
    }

    /// Enter in the footer filter: keep the selection, drop the filter and
    /// jump straight into the selected session's terminal.
    public func filterCommit() {
        filter = ""
        filterActive = false
        if selected != nil {
            setFocus(.terminal)
            onTerminalCommand?(.focus)
        }
    }
```

`.startFilter` case (`:480`) becomes:

```swift
        case .startFilter:
            filterActive = true
```

- [ ] **Step 3: StatusBar filter row** — in `Sources/covey/Views/StatusBar.swift` add tokens + focus state and swap the hints text:

```swift
struct StatusBar: View {
    let model: AppModel
    @FocusState private var filterFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        HStack(spacing: 12) {
            if model.filterActive {
                filterRow
            } else {
                Text(hints).foregroundStyle(.secondary).font(.caption)
            }
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
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            Text("/").font(.caption.monospaced()).foregroundStyle(tk.accent)
            TextField("filter", text: Binding(
                get: { model.filter }, set: { model.setFilter($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 180)
                .focused($filterFocused)
                .onAppear { filterFocused = true }
                .onExitCommand { model.filterEscape() }
                .onSubmit { model.filterCommit() }
                .onKeyPress(.downArrow) { model.apply(.selectNext); return .handled }
                .onKeyPress(.upArrow) { model.apply(.selectPrev); return .handled }
                .onKeyPress(phases: .down) { press in
                    // ⌃j/⌃k walk the filtered list; plain letters type into
                    // the field (so names containing j/k stay findable).
                    guard press.modifiers.contains(.control) else { return .ignored }
                    switch press.key {
                    case "j": model.apply(.selectNext); return .handled
                    case "k": model.apply(.selectPrev); return .handled
                    default: return .ignored
                    }
                }
            Text("\(model.visibleSessionNames().count)/\(model.sessions.count)")
                .font(.caption.monospaced()).foregroundStyle(tk.t4)
        }
    }
```

(`hints`/`modeLabel`/`focusLabel` stay as they are; in `hints` replace the non-vim text `"⌘N new · ⌘F filter"` — keep as is, still true.)

- [ ] **Step 4: Drop the sidebar filter field** — in `Sources/covey/Views/SessionListView.swift` delete the whole filter `TextField` block (with its `.focused`/`.onChange(of: model.filterFocusTick)`/`.onExitCommand`) and the now-unused `@FocusState filterFocused`.

- [ ] **Step 5: ⌘F command** — in `Sources/covey/App.swift` the Filter Sessions command becomes:

```swift
                Button("Filter Sessions") { model?.apply(.startFilter) }
                    .keyboardShortcut("f", modifiers: .command)
```

- [ ] **Step 6: Green + full suite**

Run: `swift test --filter AppModelChromeTests && swift test`
Expected: PASS.

- [ ] **Step 7: Full smoke (slice 20)**

```bash
swift run covey
```

1. Ayu Mirage everywhere: window bg `#181C26`-family, cards `#242936`, accent gold on prominent buttons; theme toggle → ayu Light; terminal shows ayu ANSI colors (run something colorful, e.g. `ls -G` / a claude session).
2. Topbar: traffic lights inline with `covey · counts … ☾ · clock`; no Standard/Git, no `+` anywhere.
3. `⌘N`: sheet has `New | Recent`; Recent lists stopped sessions with ages; ↑/↓ + Enter relaunches and closes; empty state reads `no recently-stopped sessions`.
4. `/`: footer swaps hints for the filter input (auto-focused); typing narrows the list and shows `N/M`; ⌃j/⌃k and ↑/↓ move the selection through filtered cards; Enter clears the filter and focuses the selected session's terminal; Esc clears and returns keys to the list.
5. Plain `Tab` does nothing; `⇧Tab` still reaches the agent.

- [ ] **Step 8: Hand the commit to the user**

```bash
git add Sources/covey/AppModel.swift Sources/covey/Views/StatusBar.swift Sources/covey/Views/SessionListView.swift Sources/covey/App.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): footer filter on slash — ctrl-j/k navigation, enter to terminal"
```
