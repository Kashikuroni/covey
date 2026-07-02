# Slice 4 — CoveyKit IPCClient (Design Spec)

> Дата: 2026-07-02
> Источник верхнеуровневого брифа: `HANDOFF.md` (§2 «covey — тонкий клиент», §4 «IPC protocol»,
> «Restart / restore semantics», §11 layout: `CoveyKit/IPCClient.swift`).
> Это спека **четвёртого среза**: клиентская сторона NDJSON-протокола поверх unix-сокета —
> библиотека для будущего SwiftUI GUI (срез 5). Демон (срезы 1–3) готов: сокет-сервер,
> все 8 операций, события, статусы.

## 0. Контекст и метод

- Срезы 1–3 дали `coveyd`: PTY-ядро, IPC-сервер (`list/create/kill/rename/attach/detach/
  input/resize` + события `output/sessionAdded/sessionRemoved/exited/statusChanged`),
  инференс статуса.
- Срез 4 — потребляющая сторона: `IPCClient` в `CoveyKit` + `DaemonLauncher.ensureDaemon`
  (решение брейнсторма: LaunchAgent-plist — позже, к GUI-срезу).
- Метод: TDD (скелет → тест → реализация), проверка — сборка тестов + прямой запуск
  бандла xctest. Git-операции записи — за пользователем.

## 1. Решения брейнсторма

- **API — async/await**: типизированные запросы `try await client.list()`, события —
  один `AsyncStream<DaemonEvent>`. Потребитель — SwiftUI `AppModel` (@Observable) в срезе 5.
- **Транспорт — GCD** (как `Connection` в демоне): POSIX-сокет + read-`DispatchSource`
  на serial-очереди, `LineFramer`; запросы мостятся в async через
  `withCheckedThrowingContinuation`, матчинг по `id`. Network.framework / SwiftNIO
  отклонены (нет выигрыша на локальном UDS, лишние зависимости).
- **Без авто-reconnect** (YAGNI): клиент одноразовый — разрыв переводит его в `closed`
  навсегда; GUI сам делает `ensureDaemon` + новый клиент + `list`/re-attach
  (ровно семантика «GUI restart» из HANDOFF).
- **ensureDaemon в срезе**: probe-connect; если сокет мёртв — спавн бинаря демона и
  ожидание живого сокета poll'ом.

## 2. Границы среза

### В scope
- `CoveyKit/IPCClient.swift` — соединение, запросы, события.
- `CoveyKit/DaemonLauncher.swift` — `ensureDaemon(socketPath:binaryPath:timeout:)`.
- **Переезд** `NDJSONCodec.swift` (enum `NDJSON` + `LineFramer`, 44 строки) из
  `CoveydCore` в `CoveyKit`: нужен обеим сторонам; `CoveydCore` уже импортирует
  `CoveyKit`, вызовы не меняются. Тест `NDJSONCodecTests` переезжает в `CoveyKitTests`.
- Dev-зависимость `CoveyKitTests` → `CoveydCore` (in-process сервер в интеграционных тестах).

### Отложено
- LaunchAgent (plist, launchctl) — GUI-срез.
- Авто-reconnect, бэкпрешер на медленный UI (симметрично серверному TODO).
- `StateStore`/`UsageService` (HANDOFF §11) — отдельные куски GUI-среза.

## 3. Компоненты и API

```
CoveyKit/
  NDJSONCodec.swift     — ПЕРЕЕЗД из CoveydCore (без изменений)
  IPCClient.swift       — НОВОЕ
  DaemonLauncher.swift  — НОВОЕ
CoveydCore/
  NDJSONCodec.swift     — УДАЛЯЕТСЯ (переехал)
```

```swift
public enum IPCClientError: Error, Equatable {
    case notConnected                       // запрос до connect() / после close()
    case connectFailed(Int32)               // errno connect(2) или таймаут ensureDaemon
    case daemonError(code: String, message: String)   // .error из ответа демона
    case disconnected                       // EOF/разрыв во время ожидания ответа
}

public final class IPCClient {
    public init(path: String)
    public func connect() throws            // синхронный connect(2)
    public func close()

    /// Все события демона (включая output). Один долгоживущий поток,
    /// bufferingPolicy .unbounded, завершается на EOF/close().
    public var events: AsyncStream<DaemonEvent> { get }

    public func list() async throws -> (sessions: [Session], statuses: [String: Status])
    public func create(dir: String, agent: String, argv: [String]? = nil,
                       name: String? = nil) async throws -> Session
    public func kill(name: String) async throws
    public func rename(name: String, newName: String) async throws
    public func attach(name: String, sinceSeq: Int? = nil) async throws
    public func detach(name: String) async throws
    public func input(name: String, bytes: [UInt8]) async throws   // base64 внутри
    public func resize(name: String, cols: UInt16, rows: UInt16) async throws
}

public enum DaemonLauncher {
    /// Возвращается, когда по socketPath отвечает живой демон.
    /// Сокет жив — no-op; мёртв/отсутствует — spawn(binaryPath), затем
    /// poll-connect каждые 50 мс до timeout; не дождались — connectFailed.
    /// Мёртвый файл сокета НЕ удаляем — это делает сам демон при старте.
    public static func ensureDaemon(socketPath: String, binaryPath: String,
                                    timeout: TimeInterval = 5) throws
}
```

## 4. Внутренности IPCClient

- Serial-очередь `covey.ipc-client`; на ней вся мутация: `pending: [Int:
  CheckedContinuation<ServerMessage.Result, Error>]`, `nextID: Int`, `closed: Bool`,
  `framer: LineFramer`.
- Общий низкоуровневый метод: `request(_ op: Request.Op) async throws ->
  ServerMessage.Result` — инкремент id, `NDJSON.encodeLine(Request(id:op:))`,
  запись в fd (цикл с EINTR, как `Connection.send`), continuation в `pending[id]`.
- Read-source: event-handler читает 4096, кормит `LineFramer`; каждая строка →
  `NDJSON.decoder.decode(ServerMessage.self)`:
  - `.response(id:result:)` → резюмировать `pending[id]` (`.error` → throw
    `daemonError`), убрать из словаря;
  - `.event(e)` → `eventsContinuation.yield(e)`;
  - непарсящаяся строка → игнор (не падаем, доверяем демону).
- EOF/ошибка чтения (`n <= 0`) или `close()` → `closed = true`, cancel read-source
  (cancel-handler закрывает fd, захват fd по значению), все `pending` резюмируются
  `disconnected`, `eventsContinuation.finish()`.
- Типизированные методы — тонкие обёртки над `request`, распаковывающие ожидаемый
  кейс `Result` (неожиданный кейс → `daemonError(code: "badResponse", ...)`).
- Паттерны из среза 2 обязательны: hoisted `pathSize` при `strlcpy` в `sockaddr_un`;
  `[weak self]` в замыканиях на очередях/сорсах; время жизни клиента держит GUI
  (selfRetain не нужен — клиент не безхозный, в отличие от серверного `Connection`).

## 5. DaemonLauncher

- Probe: `socket+connect` к socketPath (код-образец — single-instance-проверка в
  `coveyd/main.swift`); успех → закрыть probe-fd, готово.
- Иначе `Process()` с `executableURL = binaryPath`, `standardOutput/Error = nil`
  (демон сам пишет в stderr), запуск, затем цикл: probe-connect каждые 50 мс,
  суммарно ≤ timeout. Успех → готово; таймаут → `connectFailed(ETIMEDOUT)`.
- Не удаляет мёртвый файл сокета: демон при старте сам различает stale/живой
  (уже реализовано в `main.swift`).

## 6. Тесты

`CoveyKitTests` получает зависимость на `CoveydCore` (только тестовый таргет) и
поднимает in-process сервер, как `EndToEndTests`: `SessionRegistry` + `StatusMonitor` +
`IPCServer` + `SocketServer` на временном сокет-пути.

- `IPCClientTests`:
  - connect + `list` пустого реестра → `([], [:])`;
  - `create` возвращает Session; `kill("ghost")` → `daemonError(code: "notFound")`;
  - `attach` + `input("ping")` → из `events` приходит `.output` с "ping"
    (async-итерация, таймаут через `waitUntil`-эквивалент или Task+expectation);
  - `monitor.tick()` → из `events` приходит `.statusChanged`;
  - разрыв при живом pending-запросе → запрос бросает `disconnected`, итерация
    `events` завершается. В юнитах разрыв моделируется `client.close()` против
    «немого» сервера (принял соединение, не отвечает) — `SocketServer.stop()`
    закрывает только accept-source, уже принятые соединения не рвёт; настоящий
    `kill -9` демона проверяется в smoke;
  - запрос без `connect()` → `notConnected`.
- `DaemonLauncherTests`:
  - сокет уже жив (in-process сервер) → `ensureDaemon` no-op (не спавнит: binaryPath
    = "/nonexistent", успех = не бросил);
  - сокета нет, binaryPath = /usr/bin/false → `connectFailed` по таймауту (короткий
    timeout ~0.3 с).
- Спавн настоящего `.build/debug/coveyd` — не в юнитах, а в smoke-шаге плана.
- Без `sleep` в тестах — XCTestExpectation/поллинг; NDJSONCodecTests переезжают как есть.

## 7. Definition of Done

1. Сборка + все тесты зелёные (включая переехавшие NDJSONCodecTests).
2. Smoke: `ensureDaemon` поднимает реальный демон → клиент создаёт сессию, получает
   `output` и `statusChanged` через `events`, `list` отдаёт статусы.
3. `kill -9` демона при живом клиенте → pending-запрос падает `disconnected`,
   `events` завершается (без зависаний).
4. `CoveydCore` собирается без собственного NDJSONCodec (переезд чистый).
