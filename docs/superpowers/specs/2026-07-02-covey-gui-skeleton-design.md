# Slice 5 — covey GUI walking skeleton (Design Spec)

> Дата: 2026-07-02
> Источник верхнеуровневого брифа: `HANDOFF.md` (§2, §5 «Terminal integration»,
> §6 «UI surfaces», §7 «AppModel», §11 layout).
> Это спека **пятого среза**: минимальное, но живое SwiftUI-приложение поверх
> готового `IPCClient` (срез 4). Декомпозиция GUI-фазы (решение брейнсторма):
> **срез 5** — walking skeleton (эта спека); **срез 6** — `state.toml`
> (StateStore, Recent-вкладка, порядок, тема, ширины сплитов); **срез 7** —
> usage-чип, topbar counts, статус-бар, фильтр, history mode, полировка.

## 0. Контекст и метод

- Срезы 1–4 дали: демон со статусами и `IPCClient` (async/await + `AsyncStream`).
- Срез 5 — первый UI: окно, список сессий, живой терминал, ситы New/Kill/Rename.
- Метод: TDD для `AppModel` (скелет → тест → реализация), вьюхи — ручной smoke
  (`swift run covey`). Git-операции записи — за пользователем.

## 1. Решения брейнсторма

- **SwiftPM executable** `covey` в том же Package.swift; `swift run covey`
  (NSApplication без .app-бандла). Настоящий .app/LaunchAgent — поздний срез.
- **Walking skeleton**: без state.toml, без Recent, без usage, без topbar/status
  bar/инспектора, без вкладок и фильтра. Тема терминала — захардкоженный dark.
- Демон — единственный источник правды о сессиях: UI-действия зовут клиента,
  модель обновляется только событиями демона.

## 2. Границы среза

### В scope
- executableTarget `covey` (SwiftUI) + testTarget `CoveyAppTests`.
- `AppModel` (@Observable, @MainActor): sessions, statusByName, selected, modal,
  toast; единственный event-loop; действия create/kill/rename/select.
- Автоподнятие демона: `DaemonLauncher.ensureDaemon`, путь к `coveyd` — рядом с
  бинарём `covey` (в `.build/debug` они соседи; в будущем .app — тоже).
- SwiftTerm `TerminalView` через NSViewRepresentable: attach/backfill/live feed,
  ввод → `input`, ресайз → `resize`, ремоунт по `.id(sessionName)`.
- Ситы: New (NSOpenPanel), Kill (confirm), Rename.
- Обрыв демона → toast + кнопка Reconnect (ensureDaemon + новый клиент + list).

### Отложено
- Срез 6: `state.toml` (StateStore), Recent, порядок/имена проектов, тема,
  split-ширины, драфты/заметки.
- Срез 7: usage-чип, topbar (counts/часы/переключатели), статус-бар, фильтр,
  history-mode индикатор, vim/leader-мод, меню-бар шорткаты сверх базовых.
- Позже: .app-бандл, LaunchAgent, traffic-lights стилизация, инспектор, git-вьюха.

## 3. Компоненты

```
Package.swift             — + executableTarget covey (CoveyKit, SwiftTerm),
                            + testTarget CoveyAppTests (covey, CoveydCore)
Sources/covey/
  App.swift               — @main SwiftUI App; HSplitView; sheet-роутинг по model.modal
  AppModel.swift           — состояние + event-loop + действия (вся логика среза)
  TerminalController.swift — NSViewRepresentable над SwiftTerm.TerminalView + делегат
  Views/SessionListView.swift
  Views/TerminalPaneView.swift
  Views/Sheets.swift       — New / Kill / Rename
Tests/CoveyAppTests/
  AppModelTests.swift
  AppTestSupport.swift     — копия TestDaemon-харнесса (CoveyKitTests не импортируем)
```

## 4. AppModel

```swift
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable { case newSession, kill(String), rename(String) }

    public private(set) var sessions: [Session] = []          // сорт по created
    public private(set) var statusByName: [String: Status] = [:]
    public var selected: String?                              // имя выбранной сессии
    public var modal: Modal?
    public private(set) var toast: String?
    public private(set) var connected = false

    /// Байты для терминала выбранной (attached) сессии.
    /// TerminalController подписывается при маунте, nil при размаунте.
    public var onTerminalOutput: (([UInt8]) -> Void)?

    /// makeClient — фабрика «ensureDaemon + connect + новый IPCClient»; продакшен
    /// передаёт замыкание с путями (демон рядом с бинарём, сокет ~/.covey/…),
    /// тесты — замыкание на TestDaemon-сокет. reconnect() зовёт её же.
    public init(client: IPCClient, makeClient: @escaping () throws -> IPCClient)
    public func start() async                 // list + запуск event-loop
    public func select(_ name: String?) async // detach старой, attach новой (sinceSeq: 0)
    public func create(dir: String, agent: String) async
    public func kill(_ name: String) async
    public func rename(_ name: String, to newName: String) async
    public func sendInput(_ bytes: [UInt8]) async   // → input(selected)
    public func resize(cols: UInt16, rows: UInt16) async
    public func reconnect() async             // ensureDaemon + новый клиент + start()
}
```

- Event-loop — один `Task { for await e in client.events }` (events single-consumer):
  - `sessionAdded` → добавить; `sessionRemoved`/`exited` → убрать (+сбросить selected,
    если это она); `statusChanged` → словарь; `output(name,…)` → если name == attached,
    декодировать base64 и `onTerminalOutput?(bytes)`.
  - Завершение стрима → `connected = false`, toast "daemon connection lost".
- Действия ловят `IPCClientError` → toast; модель мутируют только события.
- Продакшен-обвязка (в `App.swift`): путь демона =
  `URL(fileURLWithPath: Bundle.main.executablePath!).deletingLastPathComponent()
  .appendingPathComponent("coveyd")`; сокет `~/.covey/coveyd.sock`;
  `ensureDaemon` → `IPCClient` → `AppModel(client:)` → `start()`.

## 5. Терминал (TerminalController)

- `NSViewRepresentable`, создаёт SwiftTerm `TerminalView`; НЕ
  `LocalProcessTerminalView` (процессы у демона).
- Маунт: `model.onTerminalOutput = { view.feed(byteArray: $0) }`; вызывающая вью
  делает `await model.select(name)` (attach с backfill: `sinceSeq: 0`).
- Делегат: `send(source:data:)` → `model.sendInput`; `sizeChanged(newCols:newRows:)` →
  `model.resize`. Остальные методы — no-op.
- Смена сессии: SwiftUI `.id(model.selected)` пересоздаёт вью; `select` делает
  `detach` старой перед `attach` новой.
- Тема: захардкоженный dark (HANDOFF §5): bg `#1C1917`, fg `#FAF7F2`, оранжевый
  курсор; через `installColors`/nativeBackgroundColor. Переключение — срез 6.

## 6. Вьюхи

- **Окно**: `HSplitView { SessionListView (minWidth 220) | TerminalPaneView }`.
- **SessionListView**: `List(selection:)`, секции по `session.dir`; строка:
  глиф статуса (● цветом: running=оранж, waiting=янтарь, idle=серый) + имя +
  agent. Тулбар: ＋ (New). Контекстное меню строки: Rename…, Kill….
- **TerminalPaneView**: хедер (имя · dir · agent · глиф) + TerminalController;
  placeholder "no session selected", когда selected == nil.
- **Sheets.swift**: New (dir: текстовое поле + Browse… через NSOpenPanel
  `canChooseDirectories`, agent: поле, default "claude"); Kill: confirm;
  Rename: поле с непустой валидацией. Ошибка демона → toast, сит остаётся.
- **Toast**: overlay-текст внизу + кнопка Reconnect при `!connected`.

## 7. Тесты (CoveyAppTests)

Харнесс: копия `TestDaemon` (SessionRegistry+StatusMonitor+IPCServer+SocketServer
на temp-сокете) — тестовые таргеты не импортируются друг из друга, дубль осознанный.
`AppModel` тестируется с `IPCClient` на этот сокет; `@MainActor`-тесты async.

- start → `sessions` из `list` (создать через клиент заранее), `connected == true`.
- create → событие sessionAdded → сессия появилась в модели.
- statusChanged (ручной `monitor.tick()` с menu-скрином) → `statusByName` обновился.
- kill → sessionRemoved → ушла из модели; selected сбросился.
- output-роутинг: select("a"); ввод в "b" НЕ дёргает `onTerminalOutput`, ввод в "a" —
  дёргает с корректными байтами.
- Обрыв: `client.close()` → `connected == false`, toast установлен.
- Вьюхи и NSOpenPanel — ручной smoke.

## 8. Definition of Done

1. Сборка + все тесты зелёные (включая новые AppModelTests).
2. `swift run covey`: окно открывается, демон поднимается сам (или переиспользуется
   живой).
3. New → сессия `sh`/`claude` создаётся, терминал живой: ввод, вывод, ресайз окна
   меняет cols/rows у PTY.
4. Статусы в списке меняются на живой сессии (running при выводе, waiting на
   Claude-меню, idle в покое).
5. Kill/Rename из UI работают; ошибки демона показываются toast'ом.
6. Рестарт GUI: закрыть, открыть — сессии живы, клик по сессии re-attach'ит
   с backfill'ом истории.
