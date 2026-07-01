# Slice 3 — coveyd status inference (Design Spec)

> Дата: 2026-07-01
> Источник верхнеуровневого брифа: `HANDOFF.md` (§4 «Status inference»), ground truth —
> `agents_multiplexer` ветка `feat/desktop-swift`, `crates/amux-core/src/status.rs`.
> Это спека **третьего среза**: демон сам выводит статус каждой сессии
> (running / waiting / idle) и сообщает его клиентам. CoveyKit `IPCClient` — срез 4,
> SwiftUI-оболочка — срез 5 (решение о декомпозиции принято на брейнсторме).

## 0. Контекст и метод

- Срез 2 дал рабочий IPC: `SocketServer`/`Connection`/`IPCServer` поверх
  `SessionRegistry`, события `output/sessionAdded/sessionRemoved/exited`.
- Срез 3 добавляет инференс статуса в демоне и два расширения протокола:
  событие `statusChanged` и статусы в ответе `list`.
- Метод: TDD (скелет → тест → реализация), проверка — сборка тестов +
  прямой запуск бандла xctest. Git-операции записи — за пользователем.

## 1. Ключевое отличие от Rust-оригинала

В Rust статус считал **клиент** по `tmux capture_pane` — отрендеренному видимому
экрану. У `coveyd` отрендеренного экрана нет: демон видит сырой байтовый поток PTY.
Прямой порт по хвосту scrollback не работает:

- маркер `"esc to interrupt"` навсегда остаётся в хвосте буфера после того, как
  агент закончил (tmux показывал только живой экран — маркер исчезал);
- Claude Code перерисовывает экран курсорными последовательностями без полной
  очистки — устаревшее нумерованное меню в хвосте давало бы ложный Waiting.

**Решение (принято на брейнсторме):** headless VT-движок в демоне. На каждую
сессию — SwiftTerm `Terminal` (класс-движок, без view): демон прогоняет весь вывод
PTY через VT-парсер и на тике снимает текст видимого экрана. Это точный аналог
`tmux capture_pane`; логика `status.rs` портируется 1-в-1. Цена — зависимость
`CoveydCore` от SwiftTerm и двойной VT-парсинг (демон + будущий GUI); принято.

## 2. Границы среза

### В scope
- `Status` enum в протоколе; событие `statusChanged { name, status }`.
- Статусы в ответе `list`: `{ sessions: [Session], statuses: {name: status} }`.
- Чистый порт `status.rs`: `parsePrompt` / `isWorking` / `contentHash` /
  `computeStatus` / `deriveStatus` (+ порт всех Rust-тестов).
- `ScreenModel` — обёртка headless SwiftTerm `Terminal`.
- `StatusMonitor` — тик 1.5 с, эмиссия `statusChanged` только при смене.
- SPM-зависимость SwiftTerm у `CoveydCore`.

### Отложено
- Пункты prompt-меню в протоколе (`parse_prompt` их вычисляет, но на провод не
  идут — YAGNI, добавим когда GUI попросит; решение брейнсторма).
- `stripAnsi` не портируется: текст из VT-движка уже отрендерен.
- Carry-forward статуса при сбое capture (Rust) не нужен: снимок экрана
  in-process и не падает.
- Открытые находки ревью #5 (блокирующий waitpid), #6, #7, #9 — вне среза.

## 3. Компоненты

```
CoveyKit/
  Protocol.swift        — РАСШИРЕНИЕ: enum Status; DaemonEvent.statusChanged;
                          Result.sessions(sessions:statuses:)
CoveydCore/
  StatusInference.swift  — НОВОЕ: чистые функции, порт status.rs; без IO
  ScreenModel.swift      — НОВОЕ: headless SwiftTerm Terminal; feed/resize/visibleText
  StatusMonitor.swift    — НОВОЕ: таймер 1.5 с; prevHash/prevStatus; onStatusChanged
  SessionRegistry.swift  — РАСШИРЕНИЕ: ScreenModel на сессию; feed в onOutput-цепочке;
                          resize зовёт ScreenModel.resize; snapshotScreens()
  IPCServer.swift        — РАСШИРЕНИЕ: broadcast statusChanged; статусы в list
coveyd/
  main.swift             — РАСШИРЕНИЕ: monitor.start()
Package.swift            — зависимость SwiftTerm (https://github.com/migueldeicaza/SwiftTerm)
```

Ответственности:
- `StatusInference` — чистая логика, тестируется без PTY/таймеров.
- `ScreenModel` — только VT-состояние одной сессии; ничего не знает о статусах.
- `StatusMonitor` — только опрос и диффинг статусов; ничего не знает о сокетах.
- `IPCServer` — только доставка (broadcast + list), логики инференса нет.

## 4. Порт `status.rs` (StatusInference)

```swift
public enum Status: String, Codable, Equatable {
    case running, waiting, idle
}

// Маркеры «агент работает». Claude Code рисует "esc to interrupt" пока занят.
let workingMarkers = ["esc to interrupt"]

/// Нумерованное меню в последних 20 строках экрана: подряд `1.` `2.` …,
/// префиксы ❯ > ● · срезаются, метки до 40 символов, минимум 2 пункта.
func parsePrompt(_ screen: String) -> [String]

/// Хеш экрана для in-process диффа кадров (Swift Hasher; между рестартами
/// значения нестабильны — как DefaultHasher в Rust, это ок).
func contentHash(_ s: String) -> Int

func isWorking(_ screen: String) -> Bool

/// Первое наблюдение (prev == nil) → idle; смена хеша → running.
func computeStatus(prev: Int?, current: Int) -> Status

/// Приоритет: prompt → waiting; маркер → running; иначе дифф кадров.
func deriveStatus(content: String, prevHash: Int?, currentHash: Int,
                  hasPrompt: Bool) -> Status
```

Семантика 1-в-1 с Rust (`parse_prompt` без `strip_ansi` — вход уже чистый текст).

## 5. ScreenModel

- Обёртка `SwiftTerm.Terminal` с no-op делегатом; создаётся с текущими cols×rows
  сессии, `resize` синхронизирован с `TIOCSWINSZ`.
- `feed(_ bytes: [UInt8])` — прогон вывода PTY через парсер.
- `visibleText() -> String` — текст **активного** буфера (Claude Code работает в
  alternate screen; читать нужно то, что видит пользователь).
- Потокобезопасность: SwiftTerm `Terminal` не thread-safe. `feed` и `visibleText`
  выполняются на одной serial-очереди сессии (та же, где onOutput).
- **Риск/первый шаг плана:** проверить точный headless-API SwiftTerm
  (`Terminal(delegate:options:)`, `feed(byteArray:)`, чтение строк буфера).
  Если API неудобен — тонкая прослойка, бюджет полдня.

## 6. StatusMonitor

- Один `DispatchSourceTimer` на демон, интервал 1.5 с (как поллер Rust-версии).
- `tick()` — публичный, таймер лишь его вызывает (тесты дёргают руками, без sleep).
- Тик: `registry.snapshotScreens()` → для каждой сессии `deriveStatus`;
  результат сравнивается с `prevStatus`; при смене — `onStatusChanged(name, status)`.
- Состояние: `prevHash: [String: Int]`, `prevStatus: [String: Status]`;
  запись удаляется по `onSessionRemoved`.
- `currentStatuses() -> [String: Status]` для ответа `list`; сессия без единого
  тика → `idle` (первое наблюдение в Rust тоже idle).
- Своя serial-очередь; снимки экранов забираются sync с очередей сессий.

## 7. Протокол (изменения провода)

Ломающее изменение формата `list` допустимо: клиентов, кроме тестов, ещё нет.

```jsonc
// событие (broadcast всем подключённым клиентам, как sessionAdded)
{"event":{"statusChanged":{"name":"s-1","status":"waiting"}}}

// ответ list (был {"sessions":{"_0":[...]}}):
{"response":{"id":1,"result":{"sessions":{
  "sessions":[ ...Session... ],
  "statuses":{"s-1":"running","s-2":"idle"}
}}}}
```

Swift: `DaemonEvent.statusChanged(name: String, status: Status)`;
`Result.sessions(sessions: [Session], statuses: [String: Status])`.

## 8. Тесты

- `StatusInferenceTests` — порт всех Rust-тестов: меню из 3 пунктов; одиночный
  пункт игнорируется; маркеры выбора `❯`; первый тик idle; смена хеша running;
  `isWorking`; приоритеты `deriveStatus` (prompt > marker > diff).
- `ScreenModelTests` — feed с ANSI-перерисовкой → `visibleText` содержит только
  финальный экран; ключевой кейс: кадр с "esc to interrupt", затем перерисовка
  без него → маркер исчез из visibleText (то, что ломало наивный порт).
- `StatusMonitorTests` — ручной `tick()`: контент меняется → одно событие
  running; повторный тик без изменений → событий нет; экран с меню → waiting;
  удаление сессии чистит состояние.
- IPC-интеграция — через сокет: create → вывод меню (например `printf` через
  `/bin/sh`) → `tick()` → клиент получает `statusChanged`; `list` содержит
  статусы. Без sleep — только XCTestExpectation/поллинг-хелпер.

## 9. Definition of Done

1. `swift build` + все тесты зелёные (старые 37 + новые).
2. Живой демон: создать сессию с промпт-меню → клиент получает
   `statusChanged: waiting`; `list` показывает статусы.
3. Событие эмитится только при смене статуса (нет спама на каждом тике).
4. Статусная логика байт-в-байт соответствует приоритетам `status.rs`.
