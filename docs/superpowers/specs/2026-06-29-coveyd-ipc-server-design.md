# Slice 2 — coveyd IPC-сервер (Design Spec)

> Дата: 2026-06-29
> Источник верхнеуровневого брифа: `HANDOFF.md` (§4, §11).
> Это спека **второго среза** порта `covey`: сетевой слой поверх готового
> `SessionRegistry` (срез 1). Status inference (§4 HANDOFF) сюда НЕ входит — он
> уезжает в срез 3.

## 0. Контекст и метод

- Срез 1 дал `SessionRegistry` поверх `PTYProcess`/`ScrollbackBuffer` (in-process,
  под тестами): `create/kill/list/get/attachOutput/write/resize` + `onExit`.
- Срез 2 надевает на реестр **Unix-сокет-сервер** (NDJSON request/response + события),
  чтобы будущий GUI-клиент управлял сессиями и стримил вывод.
- Метод: TDD (для нового кода — скелет → тест → реализация; для переписываемого
  `ScrollbackBuffer` — существующие тесты как страховка). Проверка — `swift test`.
- Рабочий цикл: код пишет пользователь руками по шагам; ассистент даёт шаг, объясняет,
  ревьюит. Git-операции записи — за пользователем.

## 1. Границы среза

### В scope
- POSIX Unix-domain-socket сервер + NDJSON-кадрирование.
- Протокол: request/response (`list/create/kill/rename/attach/detach/input/resize`)
  + события (`output/sessionAdded/sessionRemoved/exited`).
- **#3** из ревью среза 1: переписать эвикцию `ScrollbackBuffer` на кольцевой буфер (O(1)).
- **#4** из ревью среза 1: политика ошибок `notFound` (вместо молчаливых no-op).
- Реальный entry point `coveyd/main.swift` (сокет, single-instance, сигналы, `dispatchMain`).

### Отложено
- **Status inference** (`parse_prompt`/`content_hash`, событие `statusChanged`) — срез 3.
  Поэтому `list` пока возвращает только `[Session]` без статусов.
- Персистентность реестра, судьба детей при остановке демона — по HANDOFF вне среза.
- Backpressure на медленного клиента — известное ограничение, TODO (см. §6).
- Прочие отложенные находки ревью (#5 блокирующий waitpid, #6 нумерация имён,
  #7 край >limit append, #9 дубли) — по желанию позже.

## 2. Компоненты

Протокольные типы — в `CoveyKit` (переиспользует будущий клиент). Серверная механика —
в `CoveydCore` (ради тестируемости). `coveyd` — тонкий executable.

```
CoveyKit/
  Protocol.swift        — Request / ServerMessage / DaemonEvent (Codable)
CoveydCore/
  NDJSONCodec.swift      — Codable ⇄ строка JSON+'\n'; разбор потока байт в сообщения
  SocketServer.swift     — POSIX UDS: socket/bind/listen, accept через DispatchSource
  Connection.swift       — одно соединение: read-DispatchSource → запросы; очередь записи
  IPCServer.swift        — диспетчер: Request → SessionRegistry → Response; фан-аут событий
  SessionRegistry.swift  — РАСШИРЕНИЕ: onSessionAdded/onSessionRemoved, rename, backfill, notFound
  ScrollbackBuffer.swift — ПЕРЕПИСАТЬ эвикцию на кольцевой буфер (#3)
coveyd/
  main.swift             — entry point
```

Ответственности:
- `NDJSONCodec` — чистая трансформация байт ↔ сообщения; без сокетов и семантики протокола.
- `SocketServer` — приём соединений и жизненный цикл fd.
- `Connection` — I/O одного соединения (читает/пишет кадры), без семантики запросов.
- `IPCServer` — единственный, кто знает семантику: переводит запросы в вызовы реестра и
  раздаёт события. **Единственный потребитель колбэков реестра**; сам делает фан-аут на N
  соединений. Реестр/`PTYProcess` остаются с одиночными колбэками.

## 3. Протокол (`CoveyKit/Protocol.swift`)

### Кадрирование
Одно сообщение = одна строка JSON + `\n`. Байтовые нагрузки (ввод/вывод PTY) — base64-строки.

### Корреляция
В запросе — `id` (генерит клиент), эхо-возврат в ответе. У событий `id` нет. Клиент
сопоставляет ответ со своим запросом по `id`, не путая с интерливингом событий.

### Типы

```swift
// Client → daemon
public struct Request: Codable {
    public var id: Int
    public var op: Op

    public enum Op: Codable {
        case list
        case create(dir: String, agent: String, argv: [String]?, name: String?)
        case kill(name: String)
        case rename(name: String, newName: String)
        case attach(name: String, sinceSeq: Int?)
        case detach(name: String)
        case input(name: String, bytesB64: String)
        case resize(name: String, cols: UInt16, rows: UInt16)
    }
}

// Daemon → client: ответ (с id) либо событие (без id)
public enum ServerMessage: Codable {
    case response(id: Int, result: Result)
    case event(DaemonEvent)

    public enum Result: Codable {
        case ok                                       // kill/rename/detach/input/resize
        case session(Session)                         // create
        case sessions([Session])                      // list
        case error(code: String, message: String)    // notFound / duplicateName / spawnFailed / badRequest
    }
}

public enum DaemonEvent: Codable {
    case output(name: String, seq: Int, bytesB64: String)
    case sessionAdded(session: Session)
    case sessionRemoved(name: String)
    case exited(name: String, code: Int32)
}
```

### Решения
1. Кодирование — **автоматический Codable** для enum-ов; формат на проводе вложенный
   (`{"create":{…}}`, `{"response":{"id":1,"result":{"ok":{}}}}`). Ноль ручного кода.
2. Ошибки — `.error(code, message)`; `code` — стабильная строка.
3. `list` — только `[Session]` (статусы в срезе 3).
4. `attach.sinceSeq` опционален: `nil` → backfill с самого начала доступного (`since 0`).

## 4. Архитектура сервера

### Жизненный цикл соединения
```
listen-fd (DispatchSource) ─accept()→ Connection
  Connection.read-source → NDJSONCodec.feed → [Request] → IPCServer.handle(req, conn)
  IPCServer → registry.<вызов> → Result → conn.send(.response(id, result))
  события (output / lifecycle) → conn.send(.event(...))
  EOF/ошибка → teardown: закрыть fd, выкинуть из всех подписок
```

### SocketServer
- `socket(AF_UNIX, SOCK_STREAM)`; `unlink` устаревшего файла; `bind(sockaddr_un)`; `listen`.
  Права файла сокета 0600 (`umask`/`fchmod`).
- accept через `DispatchSource` на listen-fd → создаёт `Connection`.
- Остановка: закрыть listen-fd, `unlink` файла.

### Connection
- fd + read-`DispatchSource` + **серийная очередь записи** + буфер декодера + уникальный `id`.
- read → `codec.feed` → `Request` → `IPCServer.handle`.
- `send(_ msg: ServerMessage)` → строка → очередь записи (цикл записи до конца, как
  `PTYProcess.write`).
- EOF/ошибка → teardown, уведомляет `IPCServer`.

### IPCServer (диспетчер + брокер)
Состояние: `SessionRegistry`, набор `Connection`, карта подписок `name → Set<ConnectionID>`.
- `handle(req, conn)` — вызов реестра, `conn.send(.response(req.id, result))`.
- `attach(name, sinceSeq)` — добавить conn в `subscribers[name]`; backfill
  (`registry.backfill(name, since: sinceSeq ?? 0)`) → `output`-события **только этому conn**;
  далее живой поток — общий фан-аут.
- `detach(name)` — убрать conn из `subscribers[name]`.
- Фан-аут: на каждую сессию `IPCServer` один раз ставит `registry.attachOutput(name) {…}`,
  рассылающий `output(name, seq, b64)` текущим подписчикам.

### Расширения `SessionRegistry`
- Колбэки `onSessionAdded: ((Session)->Void)?`, `onSessionRemoved: ((String)->Void)?`
  (единственный слушатель — `IPCServer`). `onExit` остаётся.
- `rename(name:newName:) throws` — проверки `notFound`/`duplicateName`, перенос записи,
  правка `Session.name`; дёргает `onSessionRemoved(old)`+`onSessionAdded(new)`.
- `backfill(name:since:) -> (bytes:[UInt8], fromSeq:Int, gapped:Bool)?` — прокси к
  `PTYProcess.backfill`; `nil` если имени нет.
- **#4 notFound**: `kill/input/resize/attach/detach/rename` для неизвестного имени → бросают
  `RegistryError.notFound`; `IPCServer` транслирует в `.error("notFound", …)`.

### Маппинг событий
- `create` → `onSessionAdded` → broadcast `sessionAdded` всем.
- выход процесса (`onExit`) → broadcast `exited(name, code)` + чистка подписок сессии.
- `rename` → `onSessionRemoved(old)` + `onSessionAdded(new)` → broadcast обоих.
- вывод PTY → фан-аут `output` подписчикам.

### Конкурентность
Состояние `IPCServer` трогается из разных потоков (read-источники соединений; pty-очереди
через колбэки реестра). Защищаем **одной серийной очередью `IPCServer`**: все мутации и
рассылки хопают на неё. Запись в каждое соединение сериализуется его очередью записи.

## 5. #3 — кольцевой `ScrollbackBuffer`

Заменяем `removeFirst(drop)` (O(n)) на кольцо: запись/вытеснение амортизированно O(1).

- Предвыделенный `storage` размера `capacity = max(1, limit)`. Байт `seq = s` лежит по
  индексу `s % capacity`. Поля: `headSeq`, `tailSeq`, `count` (≤ capacity);
  инвариант `headSeq = tailSeq - count`.
- `append(bytes)`: `from = tailSeq`; копируем в кольцо по `tailSeq % capacity` (до 2 сегментов
  с переносом); `tailSeq += bytes.count`; `count = min(count + bytes.count, capacity)`;
  `headSeq = tailSeq - count`; вернуть `(from, tailSeq)`. Если `bytes.count >= capacity` —
  копируем только последние `capacity` байт.
- `since(seq)`: `gapped = seq < headSeq`; `effective = max(seq, headSeq)`; если
  `effective >= tailSeq` → `([], tailSeq, gapped)`; иначе читаем `tailSeq - effective` байт
  с `effective % capacity` (до 2 сегментов) → `(bytes, effective, gapped)`.

**Семантика идентична старой** — все 5 существующих тестов остаются зелёными без правок
(проверено на каждом, включая overflow/gapped). Добавить тест на чтение через границу кольца
(wrap): `limit:4`, `append("ab")`+`append("cd")`+`append("ef")`, затем `since(2) == "cdef"`.

## 6. Обработка ошибок и края

- **Невалидный запрос:** двухшаговый декод — сначала `{ id }`, потом полный `Request`. Полный
  декод упал, `id` есть → `.error("badRequest")` с этим id; `id` не извлечь → лог + пропуск.
- **Семантика:** notFound / duplicateName / spawnFailed / badRequest(битый base64) → `.error`.
- **Кадрирование:** лимит длины строки (4 МБ); превышение → `badRequest` + разрыв соединения.
- **Один экземпляр:** при старте, если файл сокета есть — пробуем connect. Успех → демон уже
  жив → выход с ошибкой. Неуспех → протухший файл → `unlink` + `bind`.
- **Разрыв клиента:** teardown, удаление из подписок, без крашей.
- **Остановка демона:** `SIGTERM`/`SIGINT` → закрыть listen-сокет, `unlink`, выход.
- **Известное ограничение (TODO):** backpressure на медленного клиента — очередь записи может
  расти; пока не ограничиваем.

## 7. Тесты (TDD)

1. **Протокол (CoveyKitTests):** round-trip каждого `Op`/`Result`/`DaemonEvent`; 2–3 «золотых»
   строки JSON для фиксации формата.
2. **NDJSONCodec (CoveydCoreTests):** подача байт кусками (разрыв посреди строки, несколько
   строк в чанке, неполный хвост + дополнение); `encode → строка+\n`.
3. **ScrollbackBuffer:** 5 существующих + тест на wrap.
4. **SessionRegistry:** существующие + `rename` (успех/notFound/duplicate), срабатывание
   `onSessionAdded`/`onSessionRemoved`, `notFound` из `kill/write/...`.
5. **IPCServer (логика):** `handle(req, conn)` с фейковым `Connection`, копящим
   `ServerMessage`. create→response.session, attach→backfill+output, kill→exited,
   badRequest→error, notFound→error.
6. **End-to-end сокет:** `SocketServer` на временном пути; тест-клиент `IPCTestClient`
   (`TestSupport`, NDJSON по POSIX-сокету); сценарий create→attach→input→output→kill→exited;
   несколько smoke-тестов транспорта (ожидания/таймауты).

## 8. Entry point — `coveyd/main.swift`
- Путь сокета `~/.covey/coveyd.sock` (создать `~/.covey/`, если нет).
- Single-instance (connect-or-unlink).
- Создать `SessionRegistry` + `IPCServer` + `SocketServer`, связать колбэки реестра с
  `IPCServer`, начать слушать.
- `SIGTERM`/`SIGINT` → cleanup (`unlink`) → выход.
- `dispatchMain()`.

## 9. Definition of Done (срез 2)
1. `swift build` + `swift test` зелёные.
2. Протокол round-trip + golden JSON; NDJSONCodec; ScrollbackBuffer (incl. wrap); расширенный
   SessionRegistry; IPCServer-логика; end-to-end сокет — все наборы проходят.
3. `coveyd` реально слушает `~/.covey/coveyd.sock`: клиент может create/list/kill/rename,
   attach стримит backfill+live output, kill даёт exited.
4. Неизвестное имя даёт `.error("notFound")`, а не молчаливый no-op (#4).
5. `ScrollbackBuffer` — кольцевой, эвикция без сдвига массива (#3).

## 10. Следующий срез
Срез 3: status inference (`parse_prompt`/`content_hash`, событие `statusChanged`, статусы в
`list`), затем — клиентский слой (CoveyKit `IPCClient`) и SwiftUI-оболочка.
