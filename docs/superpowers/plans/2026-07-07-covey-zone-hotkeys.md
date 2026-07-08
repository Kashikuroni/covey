# Слайс 30 — ⌘1-5 зоны, space u v, честные заголовки (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Глобальные ⌘1-5 для пяти зон (через меню View), бейджи `[N]` в заголовках зон, сплит инспектора на `space u v`, честные пер-панельные заголовки в сплите; мёртвый `s`-тогл выпилен.

**Architecture:** `AppModel.focusZone(_ zone: FocusZone)` — вытяжка активационной логики из `cycleFocus` с тостами-гардами; меню View вызывает её (menu key equivalents работают из любого фокуса). Общий `zoneTitle(...)`-хелпер для заголовков с бейджами. InspectorView ветвится: tabs-режим — прежняя строка табов, split — заголовок над каждой панелью.

**Tech Stack:** Swift (language mode v5) / SwiftUI, XCTest.

**Spec:** `/covey/docs/superpowers/specs/2026-07-07-covey-zone-hotkeys-design.md`
**Working tree:** `/Users/kashikuroni/projects/pets/covey-slice-28` (ветка `slice-28`). Baseline: 386 executed / 1 skip / 0 fail.

## Global Constraints

- Код/комментарии — английский. **Git-коммиты делает пользователь** (шаг Commit = предложить сообщение).
- TDD для model/router-логики; UI — build + suite + руками.
- Тосты дословно: `no session`, `inspector hidden — space u i`, `no split — space t v / h`.
- ⌘3/⌘4 НЕ показывают скрытый инспектор; ⌘5 НЕ создаёт сплит (решения спеки).
- `.issues` не сбрасывает экран таба (browser/composer как был).
- После добавления новых .swift-файлов — напомнить про `xcodegen generate` в финальном шаге.
- Ignore SourceKit diagnostics; верить swift build/test.

---

### Task 1: FocusZone + AppModel.focusZone (TDD)

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Produces: `public enum FocusZone: Equatable { case session, agent, note, issues, terminalSplit }` (вложен в AppModel или top-level в AppModel.swift — top-level, как KeyAction); `public func focusZone(_ zone: FocusZone)`.
- Consumes: `setFocus`, `focusPane(_:)` (AppModel.swift:273), `companion(of:)` (:427), `selectInspectorTab`, `showInspector`, `sendTerminalCommand(.blur)` (private — focusZone внутри AppModel).

- [ ] **Step 1: Тесты** — в `AppModelChromeTests.swift` (идиома makeModel/TestDaemon как в testOpenIssueListGuards):

```swift
@MainActor
func testFocusZoneGuards() async throws {
    let daemon = try TestDaemon()
    defer { daemon.stop() }
    let (model, _) = try makeModel(daemon)
    model.focusZone(.agent)
    XCTAssertEqual(model.toast, "no session")
    model.focusZone(.note)
    XCTAssertEqual(model.toast, "inspector hidden — space u i")
    model.focusZone(.issues)
    XCTAssertEqual(model.toast, "inspector hidden — space u i")
    model.focusZone(.terminalSplit)
    XCTAssertEqual(model.toast, "no split — space t v / h")
    XCTAssertNotEqual(model.focus, .inspector)   // guards never move focus
}

@MainActor
func testFocusZoneSession() async throws {
    let daemon = try TestDaemon()
    defer { daemon.stop() }
    let (model, _) = try makeModel(daemon)
    model.focusZone(.session)
    XCTAssertEqual(model.focus, .sessions)
}
```

- [ ] **Step 2: FAIL.** Run: `swift test --filter AppModelChromeTests` — компиляция падает (нет focusZone).

- [ ] **Step 3: Реализация** — в AppModel.swift, рядом с `cycleFocus` (после него):

```swift
/// ⌘1-5 zone targets (menu key equivalents — reachable from any focus).
public enum FocusZone: Equatable {
    case session, agent, note, issues, terminalSplit
}
```

(enum — top-level, перед `extension`/после класса не важно; положить прямо над классом AppModel рядом с другими top-level типами файла, если такие есть, иначе над `cycleFocus` внутри файла на top-level.)

Метод в классе:

```swift
    /// Direct zone jump for the View-menu ⌘1-5 items. Guards toast instead
    /// of mutating anything (spec: no auto-show inspector, no auto-split).
    public func focusZone(_ zone: FocusZone) {
        switch zone {
        case .session:
            sendTerminalCommand(.blur)
            setFocus(.sessions)
        case .agent:
            guard let selected else { toast = "no session"; return }
            focusPane(selected)
        case .note:
            guard showInspector else { toast = "inspector hidden — space u i"; return }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            selectInspectorTab(.note)
        case .issues:
            guard showInspector else { toast = "inspector hidden — space u i"; return }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            selectInspectorTab(.issue)
        case .terminalSplit:
            guard let selected, let comp = companion(of: selected) else {
                toast = "no split — space t v / h"; return
            }
            focusPane(comp.name)
        }
    }
```

- [ ] **Step 4: PASS.** Run: `swift test --filter AppModelChromeTests`

- [ ] **Step 5: Commit** — предложить: `feat(covey): focusZone with guard toasts for direct zone jumps`

---

### Task 2: меню View — пять пунктов ⌘1-5

**Files:**
- Modify: `Sources/covey/App.swift:100-107` (блок Focus-кнопок в CommandMenu("View"))

**Interfaces:**
- Consumes: `model?.focusZone(_:)` (Task 1).

- [ ] **Step 1: Заменить** существующие три кнопки (Focus Sessions ⌘1 / Focus Terminal ⌘2 / Focus Inspector ⌘3 c `.disabled`) на:

```swift
                Button("Focus Session") { model?.focusZone(.session) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Focus Agent") { model?.focusZone(.agent) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Focus Note") { model?.focusZone(.note) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Focus Issues") { model?.focusZone(.issues) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Focus Terminal") { model?.focusZone(.terminalSplit) }
                    .keyboardShortcut("5", modifiers: .command)
```

`.disabled(...)` не вешать — гарды тостят (меню всегда активно).

- [ ] **Step 2: Сборка + прогон.** Run: `swift build && swift test` — зелёно.

- [ ] **Step 3: Commit** — `feat(covey): View menu ⌘1-5 zone shortcuts`

---

### Task 3: space u v + выпил мёртвого s-тогла

**Files:**
- Modify: `Sources/covey/KeyRouter.swift` (routeLeader + удаление inspector-s ветки)
- Modify: `Sources/covey/Views/WhichKeyView.swift` (ui-меню)
- Modify: `Sources/covey/Views/StatusBar.swift` (инспекторные хинты)
- Modify: `Sources/covey/Views/HelpOverlay.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`

- [ ] **Step 1: Тест** — в KeyRouterTests:

```swift
func testUiLeaderRoutesInspectorSplit() {
    let ctx = KeyRouter.Context(mode: .leader(.ui), focus: .sessions,
                                vimMode: true, sheetOpen: false)
    XCTAssertEqual(KeyRouter.route(KeyInput(char: "v"), context: ctx),
                   .inspectorSplitToggle)
}

func testInspectorPlainSDoesNotToggleSplit() {
    // The dead focus==.inspector `s` mapping is removed: plain keys are
    // handed to the inspector views by the ContentView monitor and never
    // reached the router anyway.
    let ctx = KeyRouter.Context(mode: .normal, focus: .inspector,
                                vimMode: true, sheetOpen: false)
    XCTAssertNotEqual(KeyRouter.route(KeyInput(char: "s"), context: ctx),
                      .inspectorSplitToggle)
}
```

Проверь существующие KeyRouterTests: если какой-то пинит старое поведение `s` → правь его на новое ожидание (в отчёте задачи указать какой).

- [ ] **Step 2: FAIL.** Run: `swift test --filter KeyRouterTests`

- [ ] **Step 3: Реализация.**
KeyRouter.routeLeader — после `case (.ui, "t")`:

```swift
        case (.ui, "v"): return .inspectorSplitToggle
```

KeyRouter.route — удалить ветку (строки ~110-117):

```swift
        // Inspector zone extras: ⌃j/⌃k swap the split panes, `s` toggles
        // tabs<->split (list navigation never uses s here).
        if context.focus == .inspector {
            if input.isControl, ch == "j" || ch == "k" {
                return .inspectorPaneSwap
            }
            if !input.isControl, ch == "s", context.mode == .normal {
                return .inspectorSplitToggle
            }
        }
```

заменить на (⌃j/⌃k остаются!):

```swift
        // Inspector zone extras: ⌃j/⌃k swap the split panes. (The old plain
        // `s` split toggle was dead code — the ContentView monitor hands
        // plain inspector keys to the views before routing; the toggle
        // lives on `space u v` now.)
        if context.focus == .inspector, input.isControl, ch == "j" || ch == "k" {
            return .inspectorPaneSwap
        }
```

WhichKeyView ui-меню — после строки `t`:

```swift
            Row(key: "v", label: "inspector tabs / split", implemented: true),
```

и root-строку ui обновить: `"ui — panels · theme · inspector split"`.

StatusBar — инспекторный набор (не-issue): `[("space", "menu"), ("s", "tabs / split"), ("⌃h/⌃l", "zones"), ("⌃j/⌃k", "panes")]` → убрать `("s", "tabs / split")`.

HelpOverlay: строку `("⌃h/⌃l · s (inspector)", "note/issue tab · tabs/split")` → `("⌃h/⌃l (inspector)", "note/issue tab")`; добавить рядом `("⌘1-5", "zones: session · agent · note · issues · terminal")` и в блок ui-чорда упоминание `space u v` если там перечисляются (сверить текущие строки по файлу).

- [ ] **Step 4: PASS + прогон.** Run: `swift test --filter KeyRouterTests && swift test`

- [ ] **Step 5: Commit** — `feat(covey): space u v inspector split toggle; drop dead s mapping`

---

### Task 4: zoneTitle-хелпер + бейджи заголовков

**Files:**
- Create: `Sources/covey/Views/ZoneTitle.swift`
- Modify: `Sources/covey/Views/SessionListView.swift:17-21` (заголовок Session)
- Modify: `Sources/covey/Views/TerminalPaneView.swift:57-70` (paneHeader)
- Modify: `Sources/covey/Views/InspectorView.swift:36-48` (tab())

**Interfaces:**
- Produces: `func zoneTitle(_ title: String, badge: Int, active: Bool, tk: Tokens) -> some View`.

- [ ] **Step 1: Создать `Sources/covey/Views/ZoneTitle.swift`:**

```swift
import SwiftUI

/// Zone header caption with its ⌘-digit badge: "Session [1]". The badge is
/// always dim so it never competes with the active-accent title.
func zoneTitle(_ title: String, badge: Int, active: Bool, tk: Tokens) -> some View {
    HStack(spacing: 4) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? tk.accent : tk.t4)
        Text("[\(badge)]")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tk.t4)
    }
}
```

- [ ] **Step 2: SessionListView** — в заголовке зоны заменить

```swift
                Text("Session")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.focus == .sessions ? tk.accent : tk.t4)
```

на

```swift
                zoneTitle("Session", badge: 1,
                          active: model.focus == .sessions, tk: tk)
```

- [ ] **Step 3: TerminalPaneView.paneHeader** — сигнатура получает бейдж:

```swift
    private func paneHeader(_ label: String, badge: Int, name: String) -> some View {
        let active = model.focus == .terminal && model.focusedPane == name
        return HStack {
            zoneTitle(label, badge: badge, active: active, tk: tk)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
        .contentShape(Rectangle())
        .onTapGesture { if !name.isEmpty { model.focusPane(name) } }
    }
```

Call-sites (строки 18, 22, 40, 47): `paneHeader("Agent", badge: 2, name: ...)`, `paneHeader("Terminal", badge: 5, name: companion)`.

- [ ] **Step 4: InspectorView.tab()** — заменить

```swift
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? tk.accent : tk.t4)
```

на вызов zoneTitle с бейджем; сигнатура: `private func tab(_ label: String, badge: Int, _ value: AppModel.InspectorTab)`; call-sites: `tab("Note", badge: 3, .note)`, `tab("Issue", badge: 4, .issue)`:

```swift
        return zoneTitle(label, badge: badge, active: active, tk: tk)
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                model.selectInspectorTab(value)
            }
```

- [ ] **Step 5: Сборка + прогон.** Run: `swift build && swift test`

- [ ] **Step 6: Commit** — `feat(covey): zone headers carry their ⌘-digit badges`

---

### Task 5: честный сплит инспектора

**Files:**
- Modify: `Sources/covey/Views/InspectorView.swift` (body + новый paneHeader)

- [ ] **Step 1: body** — заменить текущее

```swift
        VStack(spacing: 0) {
            tabsHeader
            if model.inspectorSplit {
                NotePane(model: model)
                Divider()
                IssueBrowserPane(model: model)
            } else if model.inspectorTab == .note {
                NotePane(model: model)
            } else {
                IssueBrowserPane(model: model)
            }
        }
```

на

```swift
        VStack(spacing: 0) {
            if model.inspectorSplit {
                // Split shows both panes — a shared tab row would lie about
                // what a click does. Each pane carries its own zone header.
                paneHeader("Note", badge: 3, tab: .note)
                NotePane(model: model)
                Divider()
                paneHeader("Issue", badge: 4, tab: .issue)
                IssueBrowserPane(model: model)
            } else {
                tabsHeader
                if model.inspectorTab == .note {
                    NotePane(model: model)
                } else {
                    IssueBrowserPane(model: model)
                }
            }
        }
```

- [ ] **Step 2: paneHeader** — добавить в InspectorView:

```swift
    /// Per-pane zone header for the split mode: same strip look as the tab
    /// row, highlighted for the pane that owns the inspector focus.
    private func paneHeader(_ label: String, badge: Int,
                            tab: AppModel.InspectorTab) -> some View {
        let active = model.focus == .inspector && model.inspectorTab == tab
        return HStack {
            zoneTitle(label, badge: badge, active: active, tk: tk)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            model.setFocus(.inspector)
            model.selectInspectorTab(tab)
        }
    }
```

- [ ] **Step 3: Сборка + прогон.** Run: `swift build && swift test`

- [ ] **Step 4: Commit** — `feat(covey): honest per-pane headers in inspector split`

---

### Task 6: финальная верификация

- [ ] **Step 1: Полный прогон.** Run: `swift build && swift test` Expected: 386+4 новых ≈ 390 executed / 1 skip / 0 fail (точное число сверить).

- [ ] **Step 2: `xcodegen generate`** — добавлен новый файл ZoneTitle.swift; без регенерации app-сборка не увидит его (грабли слайса 29).

- [ ] **Step 3: Ручной чек-лист (пользователь, в собранном Covey.app):**
1. ⌘1/⌘2 — фокус список/агент из любого места, включая фокус в терминале.
2. ⌘3/⌘4 при скрытом инспекторе — тосты; при открытом — фокус в note/issues (issues сохраняет экран).
3. ⌘5 без сплита — тост; со сплитом — фокус в шелл.
4. `space u v` — тогл tabs↔split откуда угодно (кроме фокуса в терминале — леадер там не активен, как и раньше).
5. Заголовки: `Session [1]`, `Agent [2]`, `Terminal [5]`, `Note [3]`, `Issue [4]`; подсветка активной зоны.
6. В сплите — заголовок над каждой панелью, клик фокусирует; общей строки табов нет.
7. Футер инспектора больше не обещает `s`; which-key ui показывает `v`.

- [ ] **Step 4: Commit** — слайс целиком коммитит пользователь.

---

## Self-Review (выполнен)

- **Покрытие спеки:** §1 (T1+T2), §2 (T3), §3 (T4), §4 (T5), §5 тесты (T1/T3), §6 соблюдён (плейн-цифры и cycleFocus не тронуты). 
- **Плейсхолдеры:** нет.
- **Типы сквозные:** `FocusZone`/`focusZone` (T1↔T2); `zoneTitle` (T4↔T5); тосты дословно совпадают между T1-тестами и реализацией.
