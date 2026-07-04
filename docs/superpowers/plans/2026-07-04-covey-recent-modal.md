# Слайс 23 — Recent-модалка Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recent-сессии в собственной модалке на `r`: карточки, `/`-фильтр по имени+dir, j/k, Enter — рестор; таб Recent из NewSessionSheet удалён.

**Architecture:** GUI-only. Новый `Modal.recent` + `RecentSheet` (паттерн CleanupSheet: `.focusable()` + `onKeyPress`), чистая `filterRecents` рядом с `fuzzyMatch`. Рестор — существующий `relaunchRecent` (селектит и фокусит новую сессию).

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-04-covey-recent-modal-design.md`.
- Весь код и коммиты на английском.
- `swift test` перед каждым коммитом — 0 failures.
- Git-коммиты выполняет пользователь.
- SourceKit-фантомам не верить — верить `swift build`/`swift test`.

---

### Task 1: `r` → Modal.recent

**Files:**
- Modify: `Sources/covey/KeyRouter.swift` (KeyAction + routeNormal)
- Modify: `Sources/covey/AppModel.swift` (Modal + apply)
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Produces: `KeyAction.openRecent`; `AppModel.Modal.recent`; `apply(.openRecent)` → `modal = .recent`.

- [ ] **Step 1: Падающие тесты**

`Tests/CoveyAppTests/KeyRouterTests.swift` — в конец класса:

```swift
    func testRecentModalKey() {
        XCTAssertEqual(KeyRouter.route(key("r"), context: ctx()), .openRecent)
        // In the terminal the key belongs to the agent.
        XCTAssertNil(KeyRouter.route(key("r"), context: ctx(focus: .terminal)))
    }
```

`Tests/CoveyAppTests/AppModelChromeTests.swift` — в конец класса (харнесс:
`TestDaemon`/`makeModel` как у соседей файла):

```swift
    @MainActor
    func testOpenRecentShowsModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openRecent)
        XCTAssertEqual(model.modal, .recent)
    }
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter "testRecentModalKey|testOpenRecentShowsModal" 2>&1 | grep error | head -3`
Expected: `has no member 'openRecent'` / `has no member 'recent'`.

- [ ] **Step 3: Реализация**

`Sources/covey/KeyRouter.swift`:
- `KeyAction` + `case openRecent` (после `cycleFocus`).
- `routeNormal`, switch по ch (рядом с `case "n"`):

```swift
        case "r": return .openRecent
```

`Sources/covey/AppModel.swift`:
- `Modal` + `case recent`.
- `apply`, рядом с `.newSession`:

```swift
        case .openRecent:
            inputMode = .normal
            modal = .recent
```

`Sources/covey/Views/Sheets.swift` — `Modal.id` switch + `case .recent: return "recent"`.
`Sources/covey/Views/ContentView.swift` — sheet-switch + `case .recent: RecentSheet(model: model)` (тип появится в Task 3; чтобы Task 1 собирался отдельно, добавить в Sheets.swift ВРЕМЕННУЮ заглушку:

```swift
struct RecentSheet: View {
    let model: AppModel
    var body: some View { Text("recent").padding(40) }
}
```

Task 3 заменит её настоящим шитом.)

- [ ] **Step 4: Прогон**

Run: `swift test --filter "KeyRouterTests|AppModelChromeTests" 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/KeyRouter.swift Sources/covey/AppModel.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Tests/CoveyAppTests/KeyRouterTests.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): r opens the recent-sessions modal (stub sheet)"
```

---

### Task 2: filterRecents

**Files:**
- Modify: `Sources/covey/Fuzzy.swift`
- Test: `Tests/CoveyAppTests/FuzzyTests.swift`

**Interfaces:**
- Consumes: `fuzzyMatch(_:_:)` (тот же файл), `RecentSession` (CoveyKit).
- Produces: `func filterRecents(_ recents: [RecentSession], filter: String) -> [RecentSession]`.

- [ ] **Step 1: Падающий тест**

`Tests/CoveyAppTests/FuzzyTests.swift` — в конец класса:

```swift
    func testFilterRecentsMatchesNameAndDir() {
        let recents = [
            RecentSession(name: "api-fix", dir: "/Users/x/work/backend", agent: "claude"),
            RecentSession(name: "notes", dir: "/Users/x/pets/covey", agent: "zsh"),
        ]
        XCTAssertEqual(filterRecents(recents, filter: "").map(\.name),
                       ["api-fix", "notes"])                      // empty -> as is
        XCTAssertEqual(filterRecents(recents, filter: "apfx").map(\.name),
                       ["api-fix"])                               // fuzzy by name
        XCTAssertEqual(filterRecents(recents, filter: "covey").map(\.name),
                       ["notes"])                                 // by dir
        XCTAssertTrue(filterRecents(recents, filter: "zzz").isEmpty)
    }
```

(Если FuzzyTests не импортирует CoveyKit — добавить `import CoveyKit`.)

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter testFilterRecentsMatchesNameAndDir 2>&1 | grep error | head -2`
Expected: `cannot find 'filterRecents' in scope`.

- [ ] **Step 3: Реализация**

`Sources/covey/Fuzzy.swift` — в конец (+ `import CoveyKit` в шапку файла):

```swift
/// Recents narrowed by the modal's `/` filter: fuzzy over the session name
/// or its directory. Empty filter keeps the list as is.
func filterRecents(_ recents: [RecentSession], filter: String) -> [RecentSession] {
    guard !filter.isEmpty else { return recents }
    return recents.filter { fuzzyMatch(filter, $0.name) || fuzzyMatch(filter, $0.dir) }
}
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter FuzzyTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/Fuzzy.swift Tests/CoveyAppTests/FuzzyTests.swift
git commit -m "feat(covey): filterRecents - fuzzy over recent name and dir"
```

---

### Task 3: RecentSheet + чистка NewSessionSheet + подсказки

**Files:**
- Modify: `Sources/covey/Views/Sheets.swift` (заглушка → настоящий RecentSheet)
- Modify: `Sources/covey/Views/NewSessionSheet.swift` (минус таб Recent)
- Modify: `Sources/covey/Views/StatusBar.swift:87` (hint `r`)
- Modify: `Sources/covey/Views/HelpOverlay.swift` (группа act)
- Test: полный `swift test`

**Interfaces:**
- Consumes: `filterRecents` (Task 2), `Modal.recent` (Task 1), `AgentIcon(agent:tk:)`, `collapseHome`, `humanizeAge`, `model.visibleRecents()`, `model.relaunchRecent(_:)`, `latinize`.

- [ ] **Step 1: RecentSheet**

Заменить заглушку в `Sources/covey/Views/Sheets.swift` на:

```swift
/// Recently-stopped sessions: cards, `/` filter over name+dir, j/k, Enter
/// relaunches (claude resumes its conversation via the stored resumeCmd).
struct RecentSheet: View {
    let model: AppModel
    @State private var cursor = 0
    @State private var filter = ""
    @State private var filtering = false
    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var items: [RecentSession] { filterRecents(model.visibleRecents(), filter: filter) }

    var body: some View {
        let rows = items
        let now = Int64(Date().timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent sessions").font(.headline)
            if rows.isEmpty {
                Text("no recently-stopped sessions")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.element.name) { idx, r in
                        card(r, now: now, current: idx == cursor)
                            .onTapGesture { relaunch(r) }
                    }
                }
            }
            if filtering {
                HStack(spacing: 6) {
                    Text("/").font(.caption.monospaced()).foregroundStyle(tk.accent)
                    TextField("filter", text: $filter)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focused($filterFocused)
                        .onSubmit { relaunchAtCursor() }
                        .onExitCommand {
                            filter = ""; filtering = false; listFocused = true
                        }
                }
            } else {
                Text("j/k move · enter restore · / filter · esc close")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 480)
        .focusable()
        .focused($listFocused)
        .onAppear { listFocused = true }
        .onKeyPress(phases: .down) { press in
            guard !filterFocused else { return .ignored }
            switch latinize(press.characters.first ?? " ") {
            case "j": move(1); return .handled
            case "k": move(-1); return .handled
            case "/": filtering = true; filterFocused = true; return .handled
            default: return .ignored
            }
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return, phases: .down) { _ in
            guard !filterFocused else { return .ignored }   // onSubmit handles it
            relaunchAtCursor(); return .handled
        }
        .onExitCommand { model.modal = nil }
        .onChange(of: filter) { _, _ in
            cursor = min(cursor, max(0, items.count - 1))
        }
    }

    private func card(_ r: RecentSession, now: Int64, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AgentIcon(agent: r.agent, tk: tk)
                Text(r.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(current ? tk.t1 : tk.t2).lineLimit(1)
                if r.resumeCmd != nil {
                    Text("↻").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                        .help("relaunch resumes the conversation")
                }
                Spacer()
                if let stopped = r.stoppedAt {
                    Text(humanizeAge(now - stopped))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                }
            }
            Text(collapseHome(r.dir))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tk.t3).lineLimit(1).truncationMode(.head)
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(current ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(current ? tk.t1 : .clear)
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        cursor = ((cursor + delta) % count + count) % count
    }

    private func relaunchAtCursor() {
        let rows = items
        guard rows.indices.contains(cursor) else { return }
        relaunch(rows[cursor])
    }

    private func relaunch(_ r: RecentSession) {
        Task {
            await model.relaunchRecent(r)
            model.modal = nil
        }
    }
}
```

- [ ] **Step 2: Чистка NewSessionSheet**

`Sources/covey/Views/NewSessionSheet.swift`:
- Удалить: `enum SheetTab`, `@State sheetTab`, `@State recentIdx`,
  `@FocusState recentFocused`, `Picker` New/Recent, ветвление
  `if sheetTab == .new { newForm } else { recentTab }` (остаётся
  `newForm`), `.onChange(of: sheetTab)`, весь `recentTab`,
  `relaunch(_:)`.
- Заголовок «New session» уже внутри newForm — Picker не заменять ничем.

- [ ] **Step 3: Подсказки**

`Sources/covey/Views/StatusBar.swift` — hintPairs normal-vim base:

```swift
            var base: [(String, String)] = [
                ("n", "new"), ("r", "recent"), ("enter", "attach"), ("d", "kill"),
                ("space", "menu"), ("/", "filter"), ("?", "help"),
            ]
```

`Sources/covey/Views/HelpOverlay.swift` — группа act, после `("n / N", …)`:

```swift
            ("r", "recent sessions"),
```

- [ ] **Step 4: Полный прогон**

Run: `swift build 2>&1 | grep -c error:; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 ошибок, 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/Views/Sheets.swift Sources/covey/Views/NewSessionSheet.swift Sources/covey/Views/StatusBar.swift Sources/covey/Views/HelpOverlay.swift
git commit -m "feat(covey): recent modal - cards, slash filter, j/k, enter restores"
```

---

### Task 4: Смоук (user) + docs commit

Рестарт демона НЕ нужен (GUI-only).

- [ ] **Step 1: Смоук по спеке §5**

1. `r` из списка — модалка Recent: иконка агента, имя, `~/путь`,
   возраст, `↻` у claude.
2. `j/k`/стрелки ходят (wrap), `Enter` — сессия ожила, модалка закрыта,
   фокус в терминале новой сессии.
3. `/` + текст — сужение по имени И пути; Esc — фильтр снят; Enter из
   фильтра — рестор курсорной.
4. Esc — модалка закрыта. В `n`-шите таба Recent больше нет.
5. Клик мышью по карточке — рестор.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/plans/2026-07-04-covey-recent-modal.md
git commit -m "docs: slice 23 implementation plan — recent modal"
```
