# Слайс 22 — терминальные сплиты: компаньон-шелл Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Открыть чистый шелл (nvim/lazygit) сплитом рядом с терминалом выбранной сессии: `space t v/h`, `⌃\` — фокус между панелями, `space t x`/exit — закрыть.

**Architecture:** Компаньон — обычная демон-сессия с полем `Session.companionOf` (имя родителя, автоимя `<parent>+sh`), скрытая из списков GUI. Демон каскадит kill/rename/promote и не кладёт компаньонов в lost. GUI переходит с единственного output-sink на пер-имённые sink'и/буферы (`attachedNames` = selected + компаньон), ввод/resize идут от Coordinator'а с его именем, `focusedPane` решает, чей терминал держит клавиатуру.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI + SwiftTerm, XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-04-covey-terminal-splits-design.md`.
- Весь код и коммиты на английском.
- Перед каждым коммитом: `swift test` — 0 failures.
- Git-коммиты выполняет пользователь.
- SourceKit-фантомам при кросс-модульных правках не верить — верить `swift build`/`swift test`.
- Смоук ОБЯЗАН начинаться с `pkill -f coveyd; rm -f ~/.covey/coveyd.sock` (протокол меняется).

---

### Task 1: Протокол — Session.companionOf + create(companionOf:)

**Files:**
- Modify: `Sources/CoveyKit/Models.swift` (struct Session)
- Modify: `Sources/CoveyKit/Protocol.swift:12-14` (Op.create)
- Modify: `Sources/CoveyKit/IPCClient.swift:77-88` (create)
- Test: `Tests/CoveyKitTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `Session.companionOf: String?` (последний параметр init, дефолт nil); `Op.create(..., resume: String?, companionOf: String?)`; `IPCClient.create(..., resume: String? = nil, companionOf: String? = nil)`.

- [ ] **Step 1: Падающий тест**

В `Tests/CoveyKitTests/ProtocolTests.swift` добавить:

```swift
    func testCreateCompanionOfRoundTrip() throws {
        let op = Request.Op.create(dir: "/tmp", agent: "sh", argv: nil, name: nil,
                                   terminal: true, worktree: nil, model: nil,
                                   effort: nil, resume: nil, companionOf: "agent-1")
        let req = Request(id: 7, op: op)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(Request.self, from: data)
        XCTAssertEqual(back, req)

        var s = Session(name: "agent-1+sh", dir: "/tmp", cwd: "/tmp",
                        agent: "zsh", created: 1)
        s.companionOf = "agent-1"
        let sdata = try JSONEncoder().encode(s)
        let sback = try JSONDecoder().decode(Session.self, from: sdata)
        XCTAssertEqual(sback.companionOf, "agent-1")
    }
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter ProtocolTests 2>&1 | grep error | head -3`
Expected: `extra argument 'companionOf' in call`, `has no member 'companionOf'`.

- [ ] **Step 3: Реализация**

`Sources/CoveyKit/Models.swift` — в `Session` после `resumeCmd`:

```swift
    /// "claude --resume <uuid>" for cold-start relaunch; nil for non-claude.
    public var resumeCmd: String?
    /// Name of the parent session when this is a split companion shell;
    /// nil for regular sessions. Companions are hidden from the GUI lists.
    public var companionOf: String?
```

и в init — параметр `companionOf: String? = nil` (последним) + `self.companionOf = companionOf`.

`Sources/CoveyKit/Protocol.swift` — кейс create:

```swift
        case create(dir: String, agent: String, argv: [String]?, name: String?,
                    terminal: Bool?, worktree: WorktreeSpec?, model: String?,
                    effort: String?, resume: String?, companionOf: String?)
```

`Sources/CoveyKit/IPCClient.swift` — create:

```swift
    public func create(dir: String, agent: String, argv: [String]? = nil,
                       name: String? = nil, terminal: Bool? = nil,
                       worktree: WorktreeSpec? = nil, model: String? = nil,
                       effort: String? = nil, resume: String? = nil,
                       companionOf: String? = nil) async throws -> Session {
        if case let .session(s) = try await request(
            .create(dir: dir, agent: agent, argv: argv, name: name,
                    terminal: terminal, worktree: worktree, model: model,
                    effort: effort, resume: resume, companionOf: companionOf)) {
            return s
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected session")
    }
```

`Sources/CoveydCore/IPCServer.swift` — матч-сайт create получает новый биндинг (пока игнорируем значение, Task 3 подключит):

```swift
        case let .create(dir, agent, argv, name, terminal, worktree, model, effort, resume, companionOf):
```

и чтобы компилировалось до Task 3, сразу под `case let`: `_ = companionOf`.

ВНИМАНИЕ: enum-кейсы протокола требуют все аргументы при конструировании — прогнать по репо `grep -rn "\.create(dir:" Sources Tests` и добавить `companionOf: nil` в каждый матч/конструктор, который не компилируется (ожидаемо: `Tests/CoveyKitTests/ProtocolTests.swift` старый round-trip, `Tests/CoveydCoreTests/IPCServerTests.swift`).

- [ ] **Step 4: Полный прогон**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: без ошибок, 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/CoveyKit/Models.swift Sources/CoveyKit/Protocol.swift Sources/CoveyKit/IPCClient.swift Sources/CoveydCore/IPCServer.swift Tests/CoveyKitTests/ProtocolTests.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(kit): Session.companionOf + create(companionOf:) protocol"
```

---

### Task 2: Registry — создание компаньона, каскады, lost-фильтр

**Files:**
- Modify: `Sources/CoveydCore/SessionRegistry.swift`
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `Session.companionOf` (Task 1).
- Produces: `SessionRegistry.create(dir:agent:argv:name:worktreeRepo:resumeCmd:companionOf:)` (новый параметр, дефолт nil); `companionName(of name: String) -> String?` (имя живого компаньона сессии); каскадный `kill(parent)`; `rename(parent)` переименовывает компаньона; persistNow без компаньонов.

- [ ] **Step 1: Падающие тесты**

В `Tests/CoveydCoreTests/SessionRegistryTests.swift` добавить (паттерны файла: argv `/bin/cat` живёт до kill; `waitUntil`-хелпер уже есть — использовать его сигнатуру как в соседних тестах):

```swift
    func testCompanionCreateCascadeKillAndRename() throws {
        var persisted: [[SessionMeta]] = []
        let reg = SessionRegistry(persisted: [], onPersist: { persisted.append($0) })
        var removed: [String] = []
        reg.onSessionRemoved = { removed.append($0) }
        let parent = try reg.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"])
        let comp = try reg.create(dir: "/tmp", agent: "zsh", argv: ["/bin/cat"],
                                  name: "\(parent.name)+sh", companionOf: parent.name)
        XCTAssertEqual(comp.companionOf, parent.name)
        XCTAssertEqual(reg.companionName(of: parent.name), comp.name)

        // persistNow must not include companions (they never become lost).
        XCTAssertFalse(persisted.last!.contains { $0.name == comp.name })
        XCTAssertTrue(persisted.last!.contains { $0.name == parent.name })

        // rename cascades: companion follows the parent's name.
        try reg.rename(name: parent.name, newName: "renamed")
        XCTAssertEqual(reg.companionName(of: "renamed"), "renamed+sh")
        XCTAssertEqual(reg.get(name: "renamed+sh")?.companionOf, "renamed")

        // kill cascades to the companion.
        reg.kill(name: "renamed")
        XCTAssertTrue(waitUntil { reg.list().isEmpty })
    }
```

(Если `waitUntil` в этом файле имеет иную сигнатуру — подстроиться под существующий хелпер, НЕ писать sleep.)

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter SessionRegistryTests.testCompanionCreateCascadeKillAndRename 2>&1 | grep -E "error" | head -3`
Expected: `extra argument 'companionOf'`, `no member 'companionName'`.

- [ ] **Step 3: Реализация в SessionRegistry.swift**

create — параметр и прокидка в Session:

```swift
    public func create (
        dir: String,
        agent: String,
        argv: [String],
        name: String? = nil,
        worktreeRepo: String? = nil,
        resumeCmd: String? = nil,
        companionOf: String? = nil
    ) throws -> Session {
```

и в конструкторе Session внутри:

```swift
        let session = Session(
            name: id, dir: dir, cwd: dir, agent: agent,
            created: clock(), git: nil, worktreeRepo: worktreeRepo,
            resumeCmd: resumeCmd, companionOf: companionOf
        )
```

Хелпер (после `get(name:)`):

```swift
    /// Name of the live companion shell of `name`, if any.
    public func companionName(of name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries.values.first { $0.session.companionOf == name }?.session.name
    }
```

Каскадный kill — заменить существующий `kill(name:)`:

```swift
    public func kill(name: String) {
        // A parent takes its companion shell down with it.
        if let comp = companionName(of: name) {
            withEntry(comp)?.process.kill()
        }
        withEntry(name)?.process.kill()
    }
```

persistNow — фильтр компаньонов (метас-источник для lost следующей жизни демона; мёртвый шелл не ресьюмится):

```swift
        let metas = entries.values.filter { $0.session.companionOf == nil }.map {
            SessionMeta(name: $0.session.name, dir: $0.session.dir,
                        agent: $0.session.agent, argv: $0.argv,
                        created: $0.session.created,
                        worktreeRepo: $0.session.worktreeRepo,
                        resumeCmd: $0.session.resumeCmd)
        } + lostMetas
```

rename — каскад после успешного переименования родителя. Заменить тело `rename(name:newName:)`:

```swift
    public func rename(name: String, newName: String) throws {
        lock.lock()
        guard var entry = entries[name] else {
            lock.unlock(); throw RegistryError.notFound(name)
        }
        if entries[newName] != nil {
            lock.unlock(); throw RegistryError.duplicateName(newName)
        }
        entry.session.name = newName
        entries[name] = nil
        entries[newName] = entry
        // Cascade: the companion follows "<parent>+sh" and its back-reference.
        var companionPair: (old: String, session: Session)?
        if var comp = entries.values.first(where: { $0.session.companionOf == name }) {
            let oldComp = comp.session.name
            comp.session.name = "\(newName)+sh"
            comp.session.companionOf = newName
            entries[oldComp] = nil
            entries[comp.session.name] = comp
            companionPair = (oldComp, comp.session)
        }
        lock.unlock()
        persistNow()
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
        if let pair = companionPair {
            onSessionRemoved?(pair.old)
            onSessionAdded?(pair.session)
        }
    }
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter SessionRegistryTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(coveyd): companion sessions - cascade kill/rename, lost filter"
```

---

### Task 3: IPCServer — авто-имя компаньона, promote-каскад

**Files:**
- Modify: `Sources/CoveydCore/IPCServer.swift` (кейсы create и promote)
- Test: `Tests/CoveydCoreTests/IPCServerTests.swift`

**Interfaces:**
- Consumes: `registry.create(companionOf:)`, `registry.companionName(of:)`, `registry.kill(name:)` (Task 2).
- Produces: create с `companionOf` игнорирует клиентское имя и берёт `"\(parent)+sh"`; у promote компаньон убит до `GitOps.promoteWorktree`.

- [ ] **Step 1: Падающий тест**

В `Tests/CoveydCoreTests/IPCServerTests.swift` (по паттернам файла: серверный харнесс и sink-заглушка уже есть — использовать существующие хелперы создания сервера/запросов):

```swift
    func testCreateCompanionDerivesNameAndKillCascades() throws {
        let (server, sink) = makeServer()   // существующий хелпер файла; подстроиться под его имя
        send(server, sink, .create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                                   name: "agent", terminal: nil, worktree: nil,
                                   model: nil, effort: nil, resume: nil, companionOf: nil))
        send(server, sink, .create(dir: "/tmp", agent: "zsh", argv: ["/bin/cat"],
                                   name: "ignored", terminal: nil, worktree: nil,
                                   model: nil, effort: nil, resume: nil, companionOf: "agent"))
        // The daemon derives the companion name, ignoring the client's.
        XCTAssertTrue(sink.sessions.contains { $0.name == "agent+sh" && $0.companionOf == "agent" })
        send(server, sink, .kill(name: "agent", removeWorktree: nil))
        XCTAssertTrue(waitUntil { sink.removedNames.contains("agent+sh") })
    }
```

ВНИМАНИЕ: точные имена хелперов (`makeServer`, `send`, `sink.sessions`, `waitUntil`) взять из существующих тестов файла — тест писать в их стиле, семантика ассертов из блока выше обязательна.

Дополнительно: в существующий promote-тест (testPromoteGuardsAndCleanupFlow) добавить компаньона у worktree-сессии перед promote и ассерты: promote отвечает ok, компаньон получил sessionRemoved (убит ДО снятия worktree — иначе promoteWorktree упал бы на занятом дереве).

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter IPCServerTests.testCreateCompanionDerivesNameAndKillCascades 2>&1 | tail -5`
Expected: FAIL (имя не derived / компаньон не каскадится — до правок сервер игнорирует companionOf).

- [ ] **Step 3: Реализация**

В кейсе create IPCServer.swift: убрать `_ = companionOf`; имя и прокидка:

```swift
        case let .create(dir, agent, argv, name, terminal, worktree, model, effort, resume, companionOf):
            do {
                // A companion's name is derived, never client-chosen.
                let effectiveName = companionOf.map { "\($0)+sh" } ?? name
                let s: Session
                if let argv {   // explicit argv: the raw path (tests, compatibility)
                    s = try registry.create(dir: dir, agent: agent, argv: argv,
                                            name: effectiveName, companionOf: companionOf)
                } else {
                    let spec = CreateSpec(name: effectiveName, dir: expandTilde(dir), agent: agent,
                                          terminal: terminal ?? false, worktree: worktree,
                                          model: model, effort: effort, resume: resume)
                    // Git IO runs here, outside any registry lock.
                    let prepared = try CreateService.prepare(spec)
                    s = try registry.create(dir: prepared.finalDir, agent: prepared.label,
                                            argv: prepared.argv, name: effectiveName,
                                            worktreeRepo: prepared.worktreeRepo,
                                            resumeCmd: prepared.resumeCmd,
                                            companionOf: companionOf)
                }
                attachOutputFanout(for: s.name)
                reply(.session(s))
```

В кейсе promote — компаньона убить до promoteWorktree (его cwd внутри worktree):

```swift
        case let .promote(name):
            guard let session = registry.get(name: name) else { return notFound(name) }
            guard let repo = session.worktreeRepo else {
                return reply(.error(code: "promoteFailed", message: "not a worktree session"))
            }
            guard let branch = GitOps.currentBranch(session.dir) else {
                return reply(.error(code: "promoteFailed", message: "no branch checked out"))
            }
            if let comp = registry.companionName(of: name) { registry.kill(name: comp) }
            do {
                try GitOps.promoteWorktree(repo: repo, wtDir: session.dir, branch: branch)
                reply(.ok)
            } catch { reply(.error(code: "promoteFailed", message: "\(error)")) }
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter "IPCServerTests|SessionRegistryTests" 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/CoveydCore/IPCServer.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(coveyd): derive companion name, cascade promote/kill to companion"
```

---

### Task 4: KeyRouter + WhichKey — группа t, ⌃\\

**Files:**
- Modify: `Sources/covey/KeyRouter.swift`
- Modify: `Sources/covey/Views/WhichKeyView.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`

**Interfaces:**
- Produces: `KeyAction.splitVertical/.splitHorizontal/.splitClose/.splitFocusToggle`; `LeaderMenu.terminal`; роуты `space t v/h/x`, `⌃\` в terminal- и normal-фокусе.

- [ ] **Step 1: Падающие тесты**

В `Tests/CoveyAppTests/KeyRouterTests.swift` (стиль соседних тестов — хелперы контекста файла):

```swift
    func testTerminalSplitChords() {
        let normal = KeyRouter.Context(mode: .normal, focus: .sessions, vimMode: true, sheetOpen: false)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "t"),
                                       context: .init(mode: .leader(.root), focus: .sessions,
                                                      vimMode: true, sheetOpen: false)),
                       .leaderDescend(.terminal))
        let leaderT = KeyRouter.Context(mode: .leader(.terminal), focus: .sessions,
                                        vimMode: true, sheetOpen: false)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "v"), context: leaderT), .splitVertical)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "h"), context: leaderT), .splitHorizontal)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "x"), context: leaderT), .splitClose)
        // ⌃\ toggles pane focus from both the list and the live terminal.
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "\\", isControl: true), context: normal),
                       .splitFocusToggle)
        let term = KeyRouter.Context(mode: .normal, focus: .terminal, vimMode: true, sheetOpen: false)
        XCTAssertEqual(KeyRouter.route(KeyInput(char: "\\", isControl: true), context: term),
                       .splitFocusToggle)
    }
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter KeyRouterTests.testTerminalSplitChords 2>&1 | grep error | head -3`
Expected: `no member 'terminal'` / `no member 'splitVertical'`.

- [ ] **Step 3: Реализация KeyRouter.swift**

- `enum LeaderMenu` → `case root, git, session, app, terminal`.
- `KeyAction` — добавить:

```swift
    case splitVertical
    case splitHorizontal
    case splitClose
    case splitFocusToggle
```

- В terminal-ветке `route` (рядом с ⌃q):

```swift
        if context.focus == .terminal {
            if input.isControl, ch == "q" { return .exitTerminal }
            if input.isControl, ch == "\\" { return .splitFocusToggle }
```

- В `routeNormal`, в isControl-switch по ch:

```swift
            switch ch {
            case "k": return .scrollTerminalPage(up: true)
            case "j": return .scrollTerminalPage(up: false)
            case "\\": return .splitFocusToggle
            default: return nil
            }
```

- В `routeLeader`:

```swift
        case (.root, "t"): return .leaderDescend(.terminal)
        case (.terminal, "v"): return .splitVertical
        case (.terminal, "h"): return .splitHorizontal
        case (.terminal, "x"): return .splitClose
```

`Sources/covey/Views/WhichKeyView.swift` — в root добавить Row (после "a"):

```swift
            Row(key: "t", label: "terminal — split v · split h · close", implemented: true),
```

и новый кейс:

```swift
        case .terminal: return [
            Row(key: "v", label: "vertical split — shell beside agent", implemented: true),
            Row(key: "h", label: "horizontal split — shell below agent", implemented: true),
            Row(key: "x", label: "close split", implemented: true),
        ]
```

и в `title`:

```swift
        case .terminal: return "space t — terminal"
        }
```

`Sources/covey/AppModel.swift` — switch в `apply(_ action:)` перестанет быть исчерпывающим; временная заглушка (Task 5 заменит её настоящей обработкой):

```swift
        case .splitVertical, .splitHorizontal, .splitClose, .splitFocusToggle:
            break   // wired in the next task
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter KeyRouterTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/KeyRouter.swift Sources/covey/Views/WhichKeyView.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): space t leader group and ctrl-backslash pane toggle"
```

---

### Task 5: AppModel — пер-имённые sink'и, focusedPane, split-действия

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/CoveyKit/PersistedState.swift` (splitAxes)
- Test: `Tests/CoveyAppTests/SplitTests.swift` (новый)
- Modify: `Tests/CoveyKitTests/PersistedStateTests.swift` (splitAxes round-trip)

**Interfaces:**
- Consumes: KeyAction-кейсы (Task 4), `client.create(companionOf:)` (Task 1), события демона.
- Produces:
  - `AppModel.focusedPane: String?`
  - `AppModel.companion(of name: String) -> Session?`
  - `AppModel.visibleSessions: [Session]` (без компаньонов)
  - `AppModel.splitAxis(for name: String) -> String` ("v"/"h", дефолт "v")
  - `setTerminalSink(for name: String, _ sink: (([UInt8]) -> Void)?)`
  - `setTerminalCommandHandler(for name: String, _ h: ((TerminalCommand) -> Void)?)`
  - `sendInput(_ bytes: [UInt8], to name: String)`, `resize(cols:rows:name:)`
  - `focusPane(_ name: String)`
  - `PersistedState.splitAxes: [String: String]?`

- [ ] **Step 1: PersistedState.splitAxes + тест**

Тест в `Tests/CoveyKitTests/PersistedStateTests.swift` (стиль файла):

```swift
    func testSplitAxesRoundTrip() throws {
        var st = PersistedState()
        st.splitAxes = ["agent": "h"]
        let data = try JSONEncoder().encode(st)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(back.splitAxes, ["agent": "h"])
    }
```

Реализация в `Sources/CoveyKit/PersistedState.swift`: поле `public var splitAxes: [String: String]?` после `vimMode`, параметр `splitAxes: [String: String]? = nil` в init (перед lastVersion) + присваивание.

Run: `swift test --filter PersistedStateTests 2>&1 | grep -E "Executed .* tests" | tail -1` → PASS.

- [ ] **Step 2: Падающие SplitTests**

Создать `Tests/CoveyAppTests/SplitTests.swift`. Харнесс — как в соседних AppModel-тестах (`TestDaemon`, `makeModel`-хелпер, `eventually`): точные имена взять из `Tests/CoveyAppTests/AppTestSupport.swift` и соседей; семантика тестов:

```swift
import XCTest
@testable import covey
import CoveyKit

@MainActor
final class SplitTests: XCTestCase {
    // 1. splitVertical без выбранной сессии — тост "no session", create не звался.
    // 2. create parent (argv /bin/cat) + companion через демона:
    //    - visibleSessionNames()/counts/orderedSessions не содержат "+sh",
    //    - model.companion(of: parent) возвращает компаньона,
    //    - после sessionAdded компаньона focusedPane == компаньон.
    // 3. kill компаньона (exit) -> сплит закрыт: companion(of:) nil,
    //    focusedPane вернулся на selected.
    // 4. apply(.splitVertical) при живом компаньоне HE создаёт второго:
    //    список сессий демона не растёт (guard -> focus).
    // 5. splitAxis(for:) читает персист: openSplit пишет "v"/"h" в store,
    //    новая модель над тем же store видит ось.
    func testSplitGuardsAndLifecycle() async throws { /* по пунктам 1-4 */ }
    func testSplitAxisPersists() async throws { /* пункт 5 */ }
}
```

Тесты написать ПОЛНОСТЬЮ (без скелетов) по этим пунктам, паттерны — из AppModelChromeTests/AppModelUsageTests.

- [ ] **Step 3: Прогнать — падает**

Run: `swift test --filter SplitTests 2>&1 | grep error | head -3`
Expected: нет `companion(of:)`, `focusedPane`, split-кейсов apply.

- [ ] **Step 4: Реализация AppModel.swift**

4a. Состояние (рядом с `selected`):

```swift
    /// Terminal pane that owns the keyboard while focus == .terminal:
    /// the selected session or its companion shell.
    public private(set) var focusedPane: String?
```

Заменить одиночный sink/буфер (строки 79-91) на пер-имённые:

```swift
    /// Output sinks per session name. A terminal view mounts asynchronously
    /// after attach, so bytes (notably the attach backfill) can arrive before
    /// the sink exists — they buffer per name and flush on registration.
    private var outputSinks: [String: ([UInt8]) -> Void] = [:]
    private var outputBuffers: [String: [UInt8]] = [:]
    /// Focus/scroll command handlers per mounted terminal view.
    private var terminalCommands: [String: (TerminalCommand) -> Void] = [:]
    /// Names this client is attached to (selected + visible companion).
    private var attachedNames: Set<String> = []

    public func setTerminalSink(for name: String, _ sink: (([UInt8]) -> Void)?) {
        if let sink {
            outputSinks[name] = sink
            if let pending = outputBuffers.removeValue(forKey: name), !pending.isEmpty {
                sink(pending)
            }
        } else {
            outputSinks[name] = nil
        }
    }

    public func setTerminalCommandHandler(for name: String,
                                          _ handler: ((TerminalCommand) -> Void)?) {
        terminalCommands[name] = handler
    }
```

Прежние `onTerminalOutput` и `onTerminalCommand` УДАЛИТЬ; все вызовы `onTerminalCommand?(...)` в AppModel заменить на:

```swift
    /// Route a view command to the focused pane's terminal (fallback: selected).
    private func sendTerminalCommand(_ cmd: TerminalCommand) {
        let target = focusedPane ?? selected
        if let target { terminalCommands[target]?(cmd) }
    }
```

(в `.enterTerminal`, `.exitTerminal`, `.scrollTerminalPage`, `.scrollTerminalToBottom`, `filterCommit`).

4b. Companion-хелперы и скрытие (рядом с counts/visibleSessionNames):

```swift
    /// Sessions that get cards/numbers/counts — companions are invisible.
    public var visibleSessions: [Session] {
        sessions.filter { $0.companionOf == nil }
    }

    public func companion(of name: String) -> Session? {
        sessions.first { $0.companionOf == name }
    }

    public func splitAxis(for name: String) -> String {
        persisted.splitAxes?[name] ?? "v"
    }
```

`counts` и `orderedSessions()` переводятся с `sessions` на `visibleSessions` (в orderedSessions: `visibleSessions.filter { sessionRoot($0) == dir }...`; в orderedDirs — обе итерации по `visibleSessions`). `visibleSessionNames()` уже идёт через orderedSessions — не трогать. `restartAllClaude` — итерация `for s in visibleSessions`.

4c. select() — мульти-attach:

```swift
    public func select(_ name: String?) async {
        guard name != selected else { return }
        for n in attachedNames { try? await client.detach(name: n) }
        attachedNames = []
        outputBuffers = [:]
        selected = name
        focusedPane = name
        historyMode = false
        if let name {
            await attachPane(name)
            if let comp = companion(of: name) { await attachPane(comp.name) }
        }
    }

    private func attachPane(_ name: String) async {
        do {
            try await client.attach(name: name, sinceSeq: 0)
            attachedNames.insert(name)
        } catch { toast = errorText(error) }
    }
```

4d. Ввод/resize по имени (замена существующих):

```swift
    public func sendInput(_ bytes: [UInt8], to name: String) async {
        try? await client.input(name: name, bytes: bytes)
    }

    public func resize(cols: UInt16, rows: UInt16, name: String) async {
        try? await client.resize(name: name, cols: cols, rows: rows)
    }
```

4e. Фокус панели:

```swift
    public func focusPane(_ name: String) {
        focusedPane = name
        setFocus(.terminal)
        terminalCommands[name]?(.focus)
    }
```

4f. apply(action) — заглушку Task 4 (`break // wired in the next task`) заменить на:

```swift
        case .splitVertical: openSplit(axis: "v")
        case .splitHorizontal: openSplit(axis: "h")
        case .splitClose:
            inputMode = .normal
            guard let comp = selected.flatMap({ companion(of: $0) }) else {
                toast = "no split"; return
            }
            Task { await kill(comp.name) }
        case .splitFocusToggle:
            guard let selected, let comp = companion(of: selected) else { return }
            focusPane(focusedPane == comp.name ? selected : comp.name)
```

и приватный:

```swift
    private func openSplit(axis: String) {
        inputMode = .normal
        guard let s = selectedSession() else { toast = "no session"; return }
        if let comp = companion(of: s.name) {
            focusPane(comp.name)
            return
        }
        var axes = persisted.splitAxes ?? [:]
        axes[s.name] = axis
        persisted.splitAxes = axes
        persist()
        Task {
            do {
                _ = try await client.create(dir: s.dir, agent: "sh", terminal: true,
                                            companionOf: s.name)
            } catch { toast = errorText(error) }
        }
    }
```

ВНИМАНИЕ: `persist()` перезаписывает поля persisted — `splitAxes` НЕ входит в его список (living в persisted напрямую), менять persist() не нужно.

4g. События:

- `.sessionAdded`: после upsert добавить

```swift
            if session.companionOf == selected {
                Task {
                    await attachPane(session.name)
                    focusPane(session.name)
                }
            }
```

- `.sessionRemoved` и `.exited` (в обоих, после существующих строк очистки): 

```swift
            outputSinks[name] = nil
            outputBuffers[name] = nil
            terminalCommands[name] = nil
            attachedNames.remove(name)
            if focusedPane == name { focusedPane = selected }
```

В `.exited` НЕ пушить компаньона в recents — обернуть существующий pushRecent-блок:

```swift
            if let s = sessions.first(where: { $0.name == name }), s.companionOf == nil {
                pushRecent(...)   // существующее тело без изменений
                persist()
            }
```

- `.output`: 

```swift
        case let .output(name, _, bytesB64):
            guard attachedNames.contains(name),
                  let data = Data(base64Encoded: bytesB64) else { return }
            let bytes = [UInt8](data)
            if let sink = outputSinks[name] {
                sink(bytes)
            } else {
                outputBuffers[name, default: []].append(contentsOf: bytes)
            }
```

4h. rename выбранной: в `rename(_:to:)` после успешного вызова клиента добавить

```swift
        if name == selected {
            selected = nil            // select() guard: force re-attach chain
            await select(newName)
        }
        if var axes = persisted.splitAxes, let axis = axes.removeValue(forKey: name) {
            axes[newName] = axis
            persisted.splitAxes = axes
            persist()
        }
```

4i. Компиляция соседей: `sendShiftTab` теперь `sendInput` не трогает — он шлёт напрямую через client (как было). `answerPrompt` — без изменений. Всё, что звало `model.sendInput(bytes)`/`model.resize(cols:rows:)` (TerminalController), чинится в Task 6 — до тех пор полный набор НЕ собирается; это нормально, гнать только `swift build --target CoveyKit` после 4a-4h НЕ нужно — сразу Task 6 Step 1-2 и потом общий прогон (задачи 5 и 6 коммитятся вместе, см. Task 6 Step 5).

- [ ] **Step 5: build (ожидаемо красный только в covey-таргете видами)**

Run: `swift build 2>&1 | grep -c error`
Expected: ошибки ТОЛЬКО в TerminalController/TerminalPaneView/ContentView/StatusBar (виды — Task 6). Если падают CoveyKit/CoveydCore — чинить сейчас.

---

### Task 6: Views — сплит-раскладка, пер-панельные терминалы

**Files:**
- Modify: `Sources/covey/TerminalController.swift`
- Modify: `Sources/covey/Views/TerminalPaneView.swift`
- Modify: `Sources/covey/Views/SessionListView.swift` (если она читала model.sessions напрямую — перевести на visibleSessions; проверить)
- Test: полный `swift test`

**Interfaces:**
- Consumes: `setTerminalSink(for:)`, `setTerminalCommandHandler(for:)`, `sendInput(_:to:)`, `resize(cols:rows:name:)`, `focusPane(_:)`, `companion(of:)`, `splitAxis(for:)`, `focusedPane` (Task 5).

- [ ] **Step 1: TerminalRepresentable с именем**

`Sources/covey/TerminalController.swift`:

```swift
struct TerminalRepresentable: NSViewRepresentable {
    let model: AppModel
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model, name: name) }

    func makeNSView(context: Context) -> TerminalView {
        let view = CoveyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        let model = self.model
        let name = self.name
        view.onBufferSwitch = { Task { @MainActor in model.setHistoryMode(false) } }
        view.onFocusClick = { Task { @MainActor in model.focusPane(name) } }
        model.setTerminalCommandHandler(for: name) { [weak view] command in
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
        applyTheme(to: view)
        model.setTerminalSink(for: name) { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        // A freshly mounted pane that already owns the pane focus grabs the
        // keyboard (companion created via space t v).
        if model.focusedPane == name, model.focus == .terminal {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }
```

Coordinator: `let name: String`, init `(model:name:)`; `send` → `model.sendInput([UInt8](data), to: name)` (внутри существующего Task-хоппинга); `sizeChanged` → `model.resize(cols: cols, rows: rows, name: name)`. Комментарий про отсутствие teardown остаётся верным: перемонтаж перезаписывает sink своего же имени; сплит-панели имеют РАЗНЫЕ имена и не конфликтуют.

- [ ] **Step 2: TerminalPaneView сплит**

```swift
struct TerminalPaneView: View {
    let model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.selected,
               let session = model.sessions.first(where: { $0.name == name }) {
                header(session)
                Divider()
                if let comp = model.companion(of: name) {
                    splitBody(main: name, companion: comp.name,
                              vertical: model.splitAxis(for: name) == "v")
                } else {
                    pane(name)
                }
            } else {
                Spacer()
                Text("no session selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// 50/50 split, drag to resize (fraction is session-local, not persisted).
    @State private var fraction: CGFloat = 0.5

    @ViewBuilder
    private func splitBody(main: String, companion: String, vertical: Bool) -> some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.width : geo.size.height
            let first = max(120, min(total - 120, total * fraction))
            let layout = vertical
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pane(main)
                    .frame(width: vertical ? first : nil,
                           height: vertical ? nil : first)
                splitDivider(vertical: vertical, total: total)
                pane(companion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func pane(_ name: String) -> some View {
        TerminalRepresentable(model: model, name: name)
            .id(name)   // fresh TerminalView per session (spec §5)
            .overlay(
                Rectangle().strokeBorder(
                    model.focusedPane == name && model.companion(of: model.selected ?? "") != nil
                        ? tk.accent : .clear,
                    lineWidth: 1)
            )
    }

    private func splitDivider(vertical: Bool, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: vertical ? 5 : nil, height: vertical ? nil : 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("termsplit"))
                    .onChanged { value in
                        guard total > 0 else { return }
                        let pos = vertical ? value.location.x : value.location.y
                        fraction = min(0.85, max(0.15, pos / total))
                    }
            )
    }
```

и на GeometryReader внутри splitBody повесить `.coordinateSpace(name: "termsplit")`. `header(session)` без изменений.

ВНИМАНИЕ про рамку: без сплита рамки нет (clear) — обычный вид не меняется.

- [ ] **Step 3: Остальные вызовы**

`grep -rn "onTerminalOutput\|onTerminalCommand\|sendInput(\|resize(cols" Sources/covey Tests/CoveyAppTests` — каждое совпадение перевести на новые API:
- `filterCommit`/apply-кейсы уже в Task 5;
- тесты, регистрировавшие `model.onTerminalOutput` — на `model.setTerminalSink(for: <имя>, ...)`;
- SessionListView: `model.statusByName`/карточки уже идут через orderedSessions (компаньонов не увидят) — проверить, что прямых `model.sessions` в видах не осталось (`grep -n "model.sessions" Sources/covey/Views` — допустимо только в TerminalPaneView.body для поиска selected).

- [ ] **Step 4: Полный прогон**

Run: `swift build 2>&1 | grep error; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 ошибок, 0 failures (включая SplitTests из Task 5).

- [ ] **Step 5: Commit (user, задачи 5+6 вместе — GUI не собирается по частям)**

```bash
git add Sources/covey/AppModel.swift Sources/CoveyKit/PersistedState.swift Sources/covey/TerminalController.swift Sources/covey/Views/TerminalPaneView.swift Sources/covey/Views/SessionListView.swift Tests/CoveyAppTests/SplitTests.swift Tests/CoveyKitTests/PersistedStateTests.swift
git commit -m "feat(covey): terminal splits - companion shell pane, per-pane io routing"
```

---

### Task 7: Смоук (user) + docs commit

- [ ] **Step 1: Смоук по спеке §8**

```bash
pkill -f coveyd; rm -f ~/.covey/coveyd.sock
swift run covey
```

1. Claude-сессия → `space t v`: справа шелл в dir сессии (worktree — в worktree), фокус в нём, `lazygit` рисуется.
2. `⌃\`: фокус агент↔шелл (рамка), ввод в сфокусированную панель; из nvim `⌃\` тоже работает.
3. `exit` в шелле → сплит схлопнулся, фокус в агенте.
4. `space t h` → горизонтальный; рестарт GUI → сплит сам поднялся с той же осью.
5. Карточки компаньона нет; счётчики/1-9/фильтр его не видят.
6. `d` родителя со сплитом → умерли оба.
7. Разделитель тянется мышью; клик по панели фокусирует её.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/plans/2026-07-04-covey-terminal-splits.md
git commit -m "docs: slice 22 implementation plan — terminal splits"
```
