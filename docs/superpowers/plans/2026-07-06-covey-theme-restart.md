# Слайс 25 — предложение рестарта агентов при смене темы Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** после `space a t` предложить одной модалкой рестарт idle claude-агентов (busy не трогаем), чтобы новая тема применилась; рестарт больше не убивает companion shell.

**Architecture:** фикс демона (restart убивает только родительский PTY), чистая `themeRestartPlan(sessions:statuses:)` в Lifecycle.swift, `AppModel.offerThemeRestart()` из диспатча `.toggleTheme`, `Modal.themeRestart` + `ThemeRestartSheet` по образцу `RestartSheet`. IPC-протокол не меняется — цикл по существующему `restart(name:)`.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-06-covey-theme-restart-design.md`.
- Весь код и коммиты на английском.
- `swift test` перед каждым коммитом — 0 failures.
- Git-коммиты выполняет пользователь.
- TDD со скелетом: компилируемый скелет типа → тест → реализация.
- Живой `claude` из тестов не спавнится — claude-сессии фейкаются `argv: ["/bin/cat"]` при `agent: "claude"`.
- SourceKit-фантомам не верить — верить `swift build`/`swift test`.

---

### Task 1: Демон — restart сохраняет companion shell

Сейчас `SessionRegistry.restart` зовёт `kill(name:)`, который каскадно валит companion (`Sources/CoveydCore/SessionRegistry.swift:123-129`); respawn воскрешает только родителя — сплит схлопывается навсегда.

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift:141-157` (метод `restart`)
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: существующие `create(...companionOf:)`, `companionName(of:)`, `onRestarted`.
- Produces: `restart(name:dir:)` с прежней сигнатурой; новое поведение — companion переживает рестарт родителя. Обычный `kill(name:)` каскад не меняет.

- [ ] **Step 1: Падающий тест**

В `Tests/CoveydCoreTests/SessionRegistryTests.swift` добавить:

```swift
func testRestartKeepsCompanionAlive() throws {
    let reg = SessionRegistry()
    let parent = try reg.create(dir: "/usr", agent: "claude",
                                argv: ["/bin/cat"], name: "agent")
    _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"],
                       name: "agent+sh", companionOf: parent.name)
    let restarted = expectation(description: "restarted")
    reg.onRestarted = { s in
        XCTAssertEqual(s.name, "agent")
        restarted.fulfill()
    }
    reg.onExit = { name, _ in XCTFail("restart must not emit exit (got \(name))") }
    reg.onSessionRemoved = { name in XCTFail("restart must not remove \(name)") }
    try reg.restart(name: "agent")
    wait(for: [restarted], timeout: 5)
    XCTAssertEqual(reg.companionName(of: "agent"), "agent+sh",
                   "companion must survive the parent's restart")
    XCTAssertNotNil(reg.get(name: "agent+sh"))
    reg.onExit = nil
    reg.onSessionRemoved = nil
    reg.kill(name: "agent")
}
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter SessionRegistryTests.testRestartKeepsCompanionAlive 2>&1 | tail -5`
Expected: FAIL — `restart must not remove agent+sh` (companion гибнет по старому каскаду).

- [ ] **Step 3: Реализация**

В `SessionRegistry.restart` заменить последнюю строку `kill(name: name)` на прямое убийство только родительского PTY и поправить doc-комментарий:

```swift
    /// Kills the session's child and respawns it in place once it exits:
    /// claude resumes its conversation, anything else reruns its argv. `dir`
    /// overrides the respawn directory (return-to-root). The entry, screen and
    /// name survive; no exited/sessionRemoved events fire. Unlike `kill`, the
    /// companion shell is left alone — the parent's name stays valid across
    /// the respawn, so the companionOf link never dangles.
    public func restart(name: String, dir: String? = nil) throws {
        lock.lock()
        guard let entry = entries[name] else {
            lock.unlock(); throw RegistryError.notFound(name)
        }
        let target = dir ?? entry.session.dir
        lock.unlock()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir),
              isDir.boolValue else {
            throw RegistryError.dirMissing(target)
        }
        lock.lock()
        pendingRestart[name] = target
        lock.unlock()
        withEntry(name)?.process.kill()
    }
```

- [ ] **Step 4: Прогнать — зелёные**

Run: `swift test --filter SessionRegistryTests 2>&1 | tail -3`
Expected: PASS, включая старый `testKill...` (kill-каскад не тронут) и оба старых restart-теста.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "fix(coveyd): restart keeps the companion shell alive"
```

---

### Task 2: Чистая логика `themeRestartPlan`

**Files:**
- Modify: `Sources/covey/Lifecycle.swift` (добавить функцию в конец файла)
- Test: `Tests/CoveyAppTests/LifecycleTests.swift`

**Interfaces:**
- Consumes: `Session`, `Status` из CoveyKit (Lifecycle.swift уже импортирует CoveyKit).
- Produces: `func themeRestartPlan(sessions: [Session], statuses: [String: Status]) -> (idle: [String], busy: [String])` — свободная функция (как `confirmsRestart`), вход — `visibleSessions` (companion-шеллы уже отфильтрованы вызывающим).

- [ ] **Step 1: Скелет**

В конец `Sources/covey/Lifecycle.swift`:

```swift
/// Splits live claude sessions into restartable (idle) and kept (busy) for
/// the theme-restart offer. Missing status counts as busy — the monitor has
/// not ruled yet, and a needless restart is worse than a stale palette.
func themeRestartPlan(sessions: [Session],
                      statuses: [String: Status]) -> (idle: [String], busy: [String]) {
    ([], [])
}
```

Run: `swift build 2>&1 | tail -2` — компилируется.

- [ ] **Step 2: Падающие тесты**

В `Tests/CoveyAppTests/LifecycleTests.swift` добавить (проверить, что в шапке файла есть `import CoveyKit`; если нет — добавить):

```swift
func testThemeRestartPlanSplitsIdleFromBusy() {
    func sess(_ name: String, _ agent: String) -> Session {
        Session(name: name, dir: "/tmp", cwd: "/tmp", agent: agent, created: 0)
    }
    let sessions = [sess("a", "claude"), sess("b", "claude opus"),
                    sess("c", "claude"), sess("d", "claude"), sess("e", "sh")]
    let statuses: [String: Status] = ["a": .idle, "b": .idle, "c": .running,
                                      "d": .waiting, "e": .idle]
    let plan = themeRestartPlan(sessions: sessions, statuses: statuses)
    XCTAssertEqual(plan.idle, ["a", "b"], "multi-word claude agent still counts")
    XCTAssertEqual(plan.busy, ["c", "d"], "waiting is busy; sh is not claude")
}

func testThemeRestartPlanMissingStatusIsBusy() {
    let s = Session(name: "a", dir: "/tmp", cwd: "/tmp", agent: "claude", created: 0)
    let plan = themeRestartPlan(sessions: [s], statuses: [:])
    XCTAssertEqual(plan.idle, [])
    XCTAssertEqual(plan.busy, ["a"])
}

func testThemeRestartPlanEmptyInput() {
    let plan = themeRestartPlan(sessions: [], statuses: [:])
    XCTAssertTrue(plan.idle.isEmpty)
    XCTAssertTrue(plan.busy.isEmpty)
}
```

- [ ] **Step 3: Прогнать — падают**

Run: `swift test --filter LifecycleTests 2>&1 | tail -5`
Expected: FAIL — первые два теста (скелет возвращает пустые списки).

- [ ] **Step 4: Реализация**

Заменить тело скелета:

```swift
func themeRestartPlan(sessions: [Session],
                      statuses: [String: Status]) -> (idle: [String], busy: [String]) {
    var idle: [String] = [], busy: [String] = []
    for s in sessions where s.agent.split(separator: " ").first == "claude" {
        if statuses[s.name] == .idle { idle.append(s.name) }
        else { busy.append(s.name) }
    }
    return (idle, busy)
}
```

(Фильтр claude — тот же, что в `AppModel.restartAllClaude`, `Sources/covey/AppModel.swift:238-244`.)

- [ ] **Step 5: Прогнать — зелёные**

Run: `swift test --filter LifecycleTests 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 6: Commit (user)**

```bash
git add Sources/covey/Lifecycle.swift Tests/CoveyAppTests/LifecycleTests.swift
git commit -m "feat(covey): themeRestartPlan - split claude agents by idle/busy"
```

---

### Task 3: AppModel — Modal.themeRestart, offerThemeRestart, restartIdleClaude

**Files:**
- Modify: `Sources/covey/AppModel.swift` (enum `Modal` :12-24; методы рядом с `restartAllClaude` :238-244; диспатч `.toggleTheme` :640-642)
- Modify: `Sources/covey/Views/Sheets.swift` (`Modal.id` :5-21; скелет `ThemeRestartSheet` рядом с `RestartSheet` :287)
- Modify: `Sources/covey/Views/ContentView.swift` (switch :30-48)
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Consumes: `themeRestartPlan(sessions:statuses:)` из Task 2; существующие `restart(_:dir:)`, `visibleSessions`, `statusByName`, `setTheme(_:)`.
- Produces: `Modal.themeRestart` (без payload); `public func offerThemeRestart()`; `public func restartIdleClaude() async -> [String]` (строки ошибок `"<name>: <err>"`, пусто = успех). Task 4 полагается на эти имена и на `struct ThemeRestartSheet { let model: AppModel }`.

- [ ] **Step 1: Скелет (компилируется, поведение пустое)**

1. `Sources/covey/AppModel.swift` — в enum `Modal` после `case restartAll` добавить:

```swift
        case themeRestart
```

2. Там же, после `restartAllClaude` (:244), добавить стабы:

```swift
    /// After a theme toggle: claude reads its palette once at startup, so
    /// live agents keep the old colors until restarted. Offers a restart of
    /// the idle ones; busy agents are only counted in a toast.
    public func offerThemeRestart() {
    }

    /// Confirm handler of the theme-restart sheet: restarts every claude
    /// session still idle at confirm time (the plan is recomputed — some may
    /// have started working since the sheet opened). Returns error lines.
    public func restartIdleClaude() async -> [String] {
        []
    }
```

3. `Sources/covey/Views/Sheets.swift` — в `Modal.id` после `case .restartAll` добавить:

```swift
        case .themeRestart: return "theme-restart"
```

4. Там же, после `RestartAllSheet`, скелет шита (полная вёрстка — Task 4):

```swift
struct ThemeRestartSheet: View {
    let model: AppModel

    var body: some View {
        Text("Apply theme to agents?")
            .padding(20)
    }
}
```

5. `Sources/covey/Views/ContentView.swift` — в switch после `case .restartAll` добавить:

```swift
                case .themeRestart: ThemeRestartSheet(model: model)
```

Run: `swift build 2>&1 | tail -2` — компилируется.

- [ ] **Step 2: Падающие тесты**

В `Tests/CoveyAppTests/AppModelChromeTests.swift` добавить:

```swift
    @MainActor
    func testToggleThemeWithNoAgentsJustFlips() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let before = model.themeRaw
        model.apply(.toggleTheme)
        XCTAssertNotEqual(model.themeRaw, before)
        XCTAssertNil(model.modal)
        XCTAssertNil(model.toast)
    }

    @MainActor
    func testToggleThemeBusyClaudeShowsToast() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // No monitor tick -> no status -> the agent counts as busy.
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        model.apply(.toggleTheme)
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.toast,
                       "1 agent(s) keep old theme — restart when idle (space s u)")
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testToggleThemeIdleClaudeOpensModal() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["agent"] == .idle
        }
        model.apply(.toggleTheme)
        XCTAssertEqual(model.modal, .themeRestart)
        XCTAssertNil(model.toast)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testToggleThemeIdleShellDoesNothing() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "sh",
                                       argv: ["/bin/cat"], name: "shell")
        _ = await eventually { model.sessions.count == 1 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["shell"] == .idle
        }
        model.apply(.toggleTheme)
        XCTAssertNil(model.modal, "shells recolor live via installColors")
        XCTAssertNil(model.toast)
        daemon.registry.kill(name: "shell")
    }

    @MainActor
    func testRestartIdleClaudeSkipsBusy() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // Idle: prints a spawn marker, then sits quiet. Busy: renders a
        // numbered menu -> .waiting.
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "claude",
            argv: ["/bin/sh", "-c", "echo spawned-$$; exec cat"], name: "idler")
        _ = try daemon.registry.create(
            dir: "/tmp", agent: "claude",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "busy")
        _ = await eventually { model.sessions.count == 2 }
        _ = await eventually {
            daemon.monitor.tick()
            return model.statusByName["idler"] == .idle
                && model.statusByName["busy"] == .waiting
        }
        let errors = await model.restartIdleClaude()
        XCTAssertEqual(errors, [])
        // The respawned /bin/sh prints a second marker onto the same screen.
        _ = await eventually {
            let text = daemon.registry.snapshotScreens()["idler"] ?? ""
            return text.components(separatedBy: "spawned-").count - 1 == 2
        }
        XCTAssertNotNil(daemon.registry.get(name: "busy"),
                        "busy agent must not be restarted")
        daemon.registry.kill(name: "idler")
        daemon.registry.kill(name: "busy")
    }
```

- [ ] **Step 3: Прогнать — падают**

Run: `swift test --filter AppModelChromeTests 2>&1 | tail -8`
Expected: FAIL — `testToggleThemeBusyClaudeShowsToast` (toast nil), `testToggleThemeIdleClaudeOpensModal` (modal nil), `testRestartIdleClaudeSkipsBusy` (второй маркер не появился). Остальные два новых могут пройти (пустые стабы ничего не делают) — это ок.

- [ ] **Step 4: Реализация**

1. `offerThemeRestart` — заменить пустое тело:

```swift
    public func offerThemeRestart() {
        let plan = themeRestartPlan(sessions: visibleSessions, statuses: statusByName)
        if !plan.idle.isEmpty {
            modal = .themeRestart
        } else if !plan.busy.isEmpty {
            toast = "\(plan.busy.count) agent(s) keep old theme — restart when idle (space s u)"
        }
    }
```

2. `restartIdleClaude` — заменить тело:

```swift
    public func restartIdleClaude() async -> [String] {
        let plan = themeRestartPlan(sessions: visibleSessions, statuses: statusByName)
        var errors: [String] = []
        for name in plan.idle {
            if let err = await restart(name) { errors.append("\(name): \(err)") }
        }
        return errors
    }
```

3. Диспатч `.toggleTheme` (`AppModel.swift:640-642`) — добавить вызов:

```swift
        case .toggleTheme:
            inputMode = .normal
            setTheme(themeRaw == "dark" ? "light" : "dark")
            offerThemeRestart()
```

(`setTheme` остаётся чистым — загрузка persisted-темы при старте модалку не триггерит.)

- [ ] **Step 5: Прогнать — зелёные**

Run: `swift test --filter AppModelChromeTests 2>&1 | tail -3`
Expected: PASS все, включая старые (у них `modal`/`toast` не задеты: тем-тогглов там нет).

- [ ] **Step 6: Полный прогон**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 7: Commit (user)**

```bash
git add Sources/covey/AppModel.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): offer idle-agent restart after a theme toggle"
```

---

### Task 4: ThemeRestartSheet — полная вёрстка + смоук

**Files:**
- Modify: `Sources/covey/Views/Sheets.swift` (заменить скелет `ThemeRestartSheet`)

**Interfaces:**
- Consumes: `themeRestartPlan`, `model.visibleSessions`, `model.statusByName`, `model.restartIdleClaude()`, `model.modal`.
- Produces: финальный UI; новых API нет.

- [ ] **Step 1: Вёрстка**

Заменить скелет `ThemeRestartSheet` целиком (образец — `RestartSheet`/`RestartAllSheet` в том же файле):

```swift
/// Offered after a theme toggle: claude reads its palette once at startup,
/// so live agents keep the old colors until restarted. Idle agents restart
/// on confirm (the plan is recomputed then); busy ones are listed, untouched.
struct ThemeRestartSheet: View {
    let model: AppModel
    @State private var error: String?

    var body: some View {
        let plan = themeRestartPlan(sessions: model.visibleSessions,
                                    statuses: model.statusByName)
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply theme to agents?").font(.headline)
            Text("Idle agents restart and resume their conversation; busy ones keep the old theme until restarted by hand (space s u).")
                .font(.caption).foregroundStyle(.secondary)
            if !plan.idle.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Will restart").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.idle, id: \.self) { name in
                        Text("• \(name)").font(.caption)
                    }
                }
            }
            if !plan.busy.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keeps old theme").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.busy, id: \.self) { name in
                        Text("• \(name) — \(model.statusByName[name]?.rawValue ?? "busy")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart \(plan.idle.count)") { run() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.idle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func run() {
        Task {
            let errors = await model.restartIdleClaude()
            if errors.isEmpty { model.modal = nil }
            else { error = errors.joined(separator: " · ") }
        }
    }
}
```

Ошибка рестарта оставляет sheet открытым с инлайн-баннером; повторный Confirm пересчитает план. Кнопка дизейблится, когда все успели стать busy.

- [ ] **Step 2: Билд и полный прогон**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3`
Expected: build ok, 0 failures.

- [ ] **Step 3: Смоук (user)**

1. Запустить app, поднять двух claude-агентов; одному дать долгую задачу (busy), второго оставить в покое (idle).
2. `space a t` → sheet: idle-агент в «Will restart», busy — в «Keeps old theme» со статусом.
3. Restart → idle-агент перезапустился с новой палитрой и восстановил разговор; busy живёт со старой; сплит busy-агента (если был) не тронут.
4. Рестартнуть агента со сплитом (`space s u`) → companion shell и сплит выживают.
5. `space a t` при всех busy → тост «N agent(s) keep old theme…», модалки нет.
6. `space a t` без агентов → просто смена темы, тишина.

- [ ] **Step 4: Commit (user)**

```bash
git add Sources/covey/Views/Sheets.swift docs/superpowers/plans/2026-07-06-covey-theme-restart.md docs/superpowers/specs/2026-07-06-covey-theme-restart-design.md
git commit -m "feat(covey): theme-restart sheet - idle/busy lists, inline errors"
```
