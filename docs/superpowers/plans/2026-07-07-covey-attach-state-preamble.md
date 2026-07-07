# Attach State-Preamble Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** При attach демон восстанавливает приватные режимы терминала сессии (alt screen, mouse tracking, bracketed paste, DECCKM) преамбулой перед backfill и шлёт SIGWINCH — свежий GUI-эмулятор после рестарта covey ведёт себя как живой (нет «каши» при скролле).

**Architecture:** Daemon-only. `ScreenModel` (уже парсит весь поток каждой сессии) синтезирует DECSET-преамбулу из публичного состояния SwiftTerm `Terminal`; `IPCServer.attach` префиксует её к backfill-байтам в то же самое `output`-событие (протокол и GUI не меняются); `PTYProcess.kick()` шлёт `SIGWINCH` группе процессов для полной перерисовки.

**Tech Stack:** Swift 6, SwiftTerm (vendored checkout), XCTest.

**Spec:** `/covey/docs/superpowers/specs/2026-07-07-covey-attach-state-preamble-design.md`

## Global Constraints

- Весь код, комментарии и commit-сообщения — на английском (docs/ — русский).
- Git-операции записи (add/commit) делает ТОЛЬКО пользователь: в конце задачи предложи commit-сообщение и остановись — не выполняй `git commit` сам.
- TDD с порядком «компилируемый скелет типа → падающий тест → реализация» (скелет нужен, чтобы тест компилировался и падал по assert'у, а не по ошибке сборки).
- SourceKit-диагностика при кросс-модульных правках врёт — верить только `swift build` / `swift test`.
- Прогон тестов таргета: `swift test --filter CoveydCoreTests 2>&1 | tail -20`.
- Порядок байтов преамбулы фиксирован: `1049h` → mouse-режим → `1006h` → `2004h` → `1h`; каждый элемент только если соответствующий режим включён.

---

### Task 1: `ScreenModel.statePreamble()`

**Files:**
- Modify: `Sources/CoveydCore/ScreenModel.swift` (метод после `visibleText()`)
- Test: `Tests/CoveydCoreTests/ScreenModelTests.swift`

**Interfaces:**
- Consumes: приватные `lock`/`terminal` внутри `ScreenModel`; публичные поля SwiftTerm `Terminal`: `isCurrentBufferAlternate: Bool`, `mouseMode: MouseMode` (cases: `.off/.x10/.vt200/.buttonEventTracking/.anyEvent`), `bracketedPasteMode: Bool`, `applicationCursor: Bool`.
- Produces: `public func statePreamble() -> [UInt8]` — DECSET-байты текущего состояния; пустой массив, когда все режимы выключены. Task 3 зовёт его через `SessionRegistry`.

- [ ] **Step 1: Скелет — компилируемая заглушка**

В `Sources/CoveydCore/ScreenModel.swift` после `visibleText()`:

```swift
    /// DECSET bytes that put a fresh terminal emulator into this session's
    /// current private-mode state (alt screen, mouse tracking, bracketed
    /// paste, application cursor keys). Sent as an attach preamble: these
    /// modes are emitted once at process start and are usually evicted from
    /// the raw scrollback ring, so a re-attached GUI would otherwise stay in
    /// the normal buffer and mis-route wheel events. The mouse protocol is
    /// assumed SGR (1006): SwiftTerm keeps the actual encoding private, and
    /// claude/vim/lazygit all request SGR.
    public func statePreamble() -> [UInt8] {
        []
    }
```

- [ ] **Step 2: Проверить сборку**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Падающие тесты**

В `Tests/CoveydCoreTests/ScreenModelTests.swift` перед закрывающей скобкой класса:

```swift
    func testStatePreambleEmptyOnFreshModel() {
        XCTAssertEqual(ScreenModel().statePreamble(), [])
    }

    func testStatePreambleRestoresAltMouseAndPaste() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h"))
        XCTAssertEqual(screen.statePreamble(),
                       bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h"))
    }

    func testStatePreambleDropsResetModes() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?2004h"))
        screen.feed(bytes("\u{1b}[?1049l\u{1b}[?1002l"))
        XCTAssertEqual(screen.statePreamble(), bytes("\u{1b}[?2004h"))
    }

    // The preamble source must be the parsed terminal, not a byte scanner:
    // a DECSET torn across two pty chunks still counts.
    func testStatePreambleSurvivesChunkSplit() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?10"))
        screen.feed(bytes("49h"))
        XCTAssertEqual(screen.statePreamble(), bytes("\u{1b}[?1049h"))
    }

    func testStatePreambleAnyEventMouseAndApplicationCursor() {
        let screen = ScreenModel()
        screen.feed(bytes("\u{1b}[?1003h\u{1b}[?1h"))
        XCTAssertEqual(screen.statePreamble(),
                       bytes("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1h"))
    }
```

Замечание: в `testStatePreambleAnyEventMouseAndApplicationCursor` вход не содержит `1006h`, а выход содержит — это фиксирует допущение SGR из спеки.

- [ ] **Step 4: Убедиться, что тесты падают**

Run: `swift test --filter CoveydCoreTests.ScreenModelTests 2>&1 | tail -10`
Expected: 4 новых теста FAIL по `XCTAssertEqual` (пустой массив вместо байтов), `testStatePreambleEmptyOnFreshModel` PASS.

- [ ] **Step 5: Реализация**

Заменить тело `statePreamble()`:

```swift
    public func statePreamble() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var seq = ""
        if terminal.isCurrentBufferAlternate { seq += "\u{1b}[?1049h" }
        switch terminal.mouseMode {
        case .off: break
        case .x10: seq += "\u{1b}[?9h"
        case .vt200: seq += "\u{1b}[?1000h"
        case .buttonEventTracking: seq += "\u{1b}[?1002h"
        case .anyEvent: seq += "\u{1b}[?1003h"
        }
        if terminal.mouseMode != .off { seq += "\u{1b}[?1006h" }
        if terminal.bracketedPasteMode { seq += "\u{1b}[?2004h" }
        if terminal.applicationCursor { seq += "\u{1b}[?1h" }
        return Array(seq.utf8)
    }
```

(Doc-комментарий из Step 1 остаётся.)

- [ ] **Step 6: Тесты зелёные**

Run: `swift test --filter CoveydCoreTests.ScreenModelTests 2>&1 | tail -10`
Expected: все тесты класса PASS.

- [ ] **Step 7: Checkpoint — предложить коммит пользователю**

Предложи (сам не коммить):

```
feat(coveyd): ScreenModel.statePreamble - DECSET snapshot of private modes
```

---

### Task 2: `PTYProcess.kick()` — SIGWINCH группе

**Files:**
- Modify: `Sources/CoveydCore/PTYProcess.swift` (после `resize`, перед `kill`)
- Test: `Tests/CoveydCoreTests/PTYProcessTests.swift`

**Interfaces:**
- Consumes: приватные `queue`, `pid`, `reaped` (те же guard'ы, что в `kill()`).
- Produces: `public func kick()` — асинхронный `SIGWINCH` группе процессов; no-op для не-запущенного/пожатого процесса. Task 3 зовёт через `SessionRegistry`.

- [ ] **Step 1: Скелет**

В `Sources/CoveydCore/PTYProcess.swift` после `resize(cols:rows:)`:

```swift
    /// Nudges the child into a full repaint. TIOCSWINSZ with an unchanged
    /// size does not signal, so attach sends an explicit SIGWINCH to the
    /// process group after replaying backfill: a freshly mounted GUI
    /// emulator needs one complete frame, not the torn tail of the ring.
    public func kick() {
    }
```

- [ ] **Step 2: Сборка**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Падающий тест**

В `Tests/CoveydCoreTests/PTYProcessTests.swift`:

```swift
    func testKickDeliversSigwinch() throws {
        let p = PTYProcess()
        let ready = expectOutput(p, contains: "READY")
        try p.spawn(argv: ["/bin/sh", "-c",
                           "trap 'echo WINCHED' WINCH; echo READY; while :; do sleep 0.2; done"],
                    cols: 80, rows: 24)
        wait(for: [ready], timeout: 5)
        let winched = expectOutput(p, contains: "WINCHED")
        p.kick()
        wait(for: [winched], timeout: 5)
        p.kill()
    }
```

(`expectOutput` заменяет output-handler — маркер READY гарантирует, что trap уже установлен до kick.)

- [ ] **Step 4: Убедиться, что тест падает**

Run: `swift test --filter CoveydCoreTests.PTYProcessTests/testKickDeliversSigwinch 2>&1 | tail -8`
Expected: FAIL по таймауту ожидания "WINCHED" (~5 s).

- [ ] **Step 5: Реализация**

```swift
    public func kick() {
        queue.async { [weak self] in
            guard let self, self.pid > 0, !self.reaped else { return }
            _ = Darwin.kill(-self.pid, SIGWINCH)
        }
    }
```

- [ ] **Step 6: Тест зелёный**

Run: `swift test --filter CoveydCoreTests.PTYProcessTests 2>&1 | tail -8`
Expected: все тесты класса PASS.

- [ ] **Step 7: Checkpoint — предложить коммит пользователю**

```
feat(coveyd): PTYProcess.kick - explicit SIGWINCH for post-attach repaint
```

---

### Task 3: обёртки `SessionRegistry.statePreamble(name:)` / `.kick(name:)`

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift` (рядом с `backfill(name:since:)`, ~line 254)
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `withEntry(_:) -> (process: PTYProcess, screen: ScreenModel)?`; `ScreenModel.statePreamble() -> [UInt8]` (Task 1); `PTYProcess.kick()` (Task 2).
- Produces: `public func statePreamble(name: String) -> [UInt8]?` (nil — сессии нет), `public func kick(name: String)`. Task 4 зовёт оба.

- [ ] **Step 1: Скелет**

В `Sources/CoveydCore/SessionRegistry.swift` после `backfill(name:since:)`:

```swift
    /// DECSET preamble reproducing the session's current terminal modes
    /// (see ScreenModel.statePreamble). nil when the session doesn't exist.
    public func statePreamble(name: String) -> [UInt8]? {
        nil
    }

    /// SIGWINCH nudge so a freshly attached client gets a full repaint.
    public func kick(name: String) {
    }
```

- [ ] **Step 2: Сборка**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Падающие тесты**

В `Tests/CoveydCoreTests/SessionRegistryTests.swift`:

```swift
    func testStatePreambleReflectsSessionModes() throws {
        let reg = SessionRegistry()
        let s = try reg.create(dir: "/usr", agent: "sh", argv: [
            "/bin/sh", "-c", "printf '\\033[?1049h\\033[?1002h\\033[?1006h'; exec cat",
        ])
        waitUntil({ reg.statePreamble(name: s.name)?.isEmpty == false },
                  "modes parsed from the session stream")
        XCTAssertEqual(reg.statePreamble(name: s.name),
                       bytes("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h"))
        XCTAssertNil(reg.statePreamble(name: "ghost"))
        reg.kill(name: s.name)
    }

    func testKickReachesSessionProcess() throws {
        let reg = SessionRegistry()
        let s = try reg.create(dir: "/usr", agent: "sh", argv: [
            "/bin/sh", "-c",
            "trap 'echo WINCHED' WINCH; echo READY; while :; do sleep 0.2; done",
        ])
        var collected = [UInt8]()
        let lock = NSLock()
        reg.attachOutput(name: s.name) { chunk, _ in
            lock.lock(); collected += chunk; lock.unlock()
        }
        func output() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: collected, as: UTF8.self)
        }
        waitUntil({ output().contains("READY") }, "trap installed")
        reg.kick(name: s.name)
        waitUntil({ output().contains("WINCHED") }, "SIGWINCH delivered")
        reg.kill(name: s.name)
    }
```

- [ ] **Step 4: Убедиться, что тесты падают**

Run: `swift test --filter CoveydCoreTests.SessionRegistryTests 2>&1 | tail -10`
Expected: `testStatePreambleReflectsSessionModes` FAIL по таймауту `waitUntil` (заглушка возвращает nil), `testKickReachesSessionProcess` FAIL по таймауту "WINCHED".

- [ ] **Step 5: Реализация**

```swift
    public func statePreamble(name: String) -> [UInt8]? {
        withEntry(name)?.screen.statePreamble()
    }

    public func kick(name: String) {
        withEntry(name)?.process.kick()
    }
```

(Doc-комментарии из Step 1 остаются.)

- [ ] **Step 6: Тесты зелёные**

Run: `swift test --filter CoveydCoreTests.SessionRegistryTests 2>&1 | tail -10`
Expected: все тесты класса PASS.

- [ ] **Step 7: Checkpoint — предложить коммит пользователю**

```
feat(coveyd): registry statePreamble/kick lookups by session name
```

---

### Task 4: `IPCServer.attach` — преамбула + kick

**Files:**
- Modify: `Sources/CoveydCore/IPCServer.swift:204-211` (case `.attach`)
- Test: `Tests/CoveydCoreTests/IPCServerTests.swift`

**Interfaces:**
- Consumes: `registry.statePreamble(name:) -> [UInt8]?`, `registry.kick(name:)` (Task 3), существующие `registry.backfill(name:since:)`, `sink.send`, `subscribers`.
- Produces: поведение протокола — первое `output`-событие attach несёт `preamble + backfill` одним payload, `seq == bf.fromSeq`; событие не шлётся, когда и преамбула, и backfill пусты; после attach сессии прилетает SIGWINCH. Клиентский код не меняется.

- [ ] **Step 1: Падающий тест**

В `Tests/CoveydCoreTests/IPCServerTests.swift`:

```swift
    func testAttachPrefixesStatePreambleToBackfill() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        // The stream flips alt screen + mouse on, then the raw DECSETs age
        // out of a 1 MB ring in real sessions; the preamble must not depend
        // on them still being in the backfill.
        server.handle(Request(id: 1, op: .create(
            dir: "/usr", agent: "sh",
            argv: ["/bin/sh", "-c", "printf '\\033[?1049h\\033[?1002h\\033[?1006hFRAME'; exec cat"],
            name: "tui", terminal: nil, worktree: nil, model: nil,
            effort: nil, resume: nil, companionOf: nil)), from: sink)
        waitUntil({ registry.statePreamble(name: "tui")?.isEmpty == false },
                  "modes parsed before attach")
        server.handle(Request(id: 2, op: .attach(name: "tui", sinceSeq: nil)), from: sink)
        // Strict check: the backfill itself STARTS with the same DECSETs the
        // preamble synthesizes, so the payload must contain them twice —
        // synthesized preamble first, untouched backfill right after. A
        // plain hasPrefix(preamble) would pass even without the fix.
        let preamble = "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h"
        waitUntil({ sink.captured.contains {
            if case .event(.output("tui", _, let b64)) = $0,
               let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self)
                    .hasPrefix(preamble + preamble + "FRAME")
            }
            return false
        } }, "first output = preamble + backfill")
        server.handle(Request(id: 3, op: .kill(name: "tui", removeWorktree: nil)), from: sink)
    }
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter CoveydCoreTests.IPCServerTests/testAttachPrefixesStatePreambleToBackfill 2>&1 | tail -8`
Expected: FAIL по таймауту «first output = preamble + backfill» (сейчас первое событие — только backfill, без дублированного префикса).

- [ ] **Step 3: Реализация**

Заменить case `.attach` (`Sources/CoveydCore/IPCServer.swift:204-211`):

```swift
        case let .attach(name, sinceSeq):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name, default: []].insert(sink.id)
            // A fresh GUI emulator needs the session's private-mode state
            // (alt screen, mouse tracking) before the raw tail: those DECSETs
            // were emitted once at process start and are usually evicted from
            // the ring, leaving a re-attached terminal in the normal buffer.
            let preamble = registry.statePreamble(name: name) ?? []
            let bf = registry.backfill(name: name, since: sinceSeq ?? 0)
            let payload = preamble + (bf?.bytes ?? [])
            if !payload.isEmpty {
                sink.send(.event(.output(name: name, seq: bf?.fromSeq ?? 0,
                                         bytesB64: Data(payload).base64EncodedString())))
            }
            registry.kick(name: name)
            reply(.ok)
```

- [ ] **Step 4: Тесты зелёные (весь таргет — attach трогают и другие тесты)**

Run: `swift test --filter CoveydCoreTests 2>&1 | tail -15`
Expected: все PASS, включая существующий `testAttachStreamsBackfillAndLiveOutput` (для plain-cat сессии преамбула пуста — поведение прежнее).

- [ ] **Step 5: Полный прогон**

Run: `swift test 2>&1 | tail -5`
Expected: все таргеты зелёные.

- [ ] **Step 6: Checkpoint — предложить коммит пользователю**

```
fix(coveyd): attach restores terminal private modes and forces repaint

A fresh GUI emulator replayed only the raw ring tail; the one-shot
DECSETs from process start (alt screen, mouse tracking) were long
evicted, so a re-attached terminal stayed in the normal buffer and
wheel-scrolled over raw frame soup. Attach now prefixes a synthesized
mode preamble from ScreenModel and SIGWINCH-kicks the child for a
clean first frame.
```

---

### Task 5: Smoke — живая проверка

**Files:** нет правок; только запуск.

**Interfaces:**
- Consumes: собранный демон и GUI из этой ветки.
- Produces: подтверждение сценария из спеки §5.

- [ ] **Step 1: Пересобрать и убить старый демон (квирк stale daemon — обязательно)**

```bash
swift build 2>&1 | tail -3
pkill -f coveyd; rm -f ~/.covey/coveyd.sock
```

- [ ] **Step 2: Запустить GUI, создать claude-сессию**

Запусти app (make-таргет бандла или `swift run covey`), создай claude-сессию, дождись отрисовки TUI.

- [ ] **Step 3: Рестарт GUI (демон живёт)**

Закрой окно/процесс GUI (демон остаётся), запусти GUI снова, выбери ту же сессию.

- [ ] **Step 4: Проверить**

- Экран agent-зоны — целый кадр claude (не рваный хвост, не пусто).
- Колесо в agent-зоне НЕ скроллит «кашу» из старых кадров (роут mouseReport: чат неподвижен — ожидаемо по спеке).
- `ctrl+o` в claude + колесо — транскрипт скроллится.
- Companion-шелл: скролл колесом работает как раньше.

- [ ] **Step 5: Отчитаться пользователю**

Результаты smoke — явно, с тем, что видел. Если что-то не так — вернуться к systematic-debugging, НЕ латать вслепую.
