# coveyd IPC-сервер (Slice 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> **Метод работы:** код пишет пользователь **руками** по шагам; ассистент даёт шаг, объясняет, ревьюит. Для нового кода — приём **скелет → тест → реализация** (компилируемый скелет, потом тесты, потом начинка). Все git-операции (init/add/commit) выполняет пользователь. Шаги «Commit» — действия пользователя.

**Goal:** Надеть на готовый `SessionRegistry` Unix-сокет-сервер (NDJSON request/response + события), чтобы клиент мог управлять сессиями и стримить вывод; заодно починить #3 (кольцевой буфер) и #4 (notFound).

**Architecture:** Протокольные типы — в `CoveyKit` (Codable enum-ы). Сетевая механика — в `CoveydCore`: `NDJSONCodec` (кадрирование), `SocketServer`+`Connection` (POSIX UDS + DispatchSource), `IPCServer` (диспетчер: Request → registry → Response, фан-аут событий на N соединений). `coveyd` — тонкий executable. `IPCServer` — единственный потребитель колбэков реестра; сам мультиплексирует на соединения.

**Tech Stack:** Swift 6.3 / SwiftPM, `import Darwin` (socket/bind/listen/accept, sockaddr_un), GCD (DispatchSource, DispatchQueue), Foundation (JSONEncoder/Decoder, Data base64), XCTest.

## Global Constraints

- `swift-tools-version: 6.3`, каждый таргет — `swiftLanguageMode(.v5)`. Платформа `.macOS(.v26)`.
- Весь код и комментарии — на английском (docs — исключение).
- Ядро байт-прозрачно: `[UInt8]`/`Data`, без интерпретации VT.
- Замыкания, живущие в очередях/источниках, захватывают `self` через `[weak self]`.
- JSON-энкодер протокола: `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]` (детерминизм + читаемые слэши). Одно сообщение = одна строка + `\n`.
- `nil`-опционалы в Codable-enum опускаются на проводе (учтено в golden-тестах).
- Пути файлов — от корня в форме `/covey/<путь>`.
- Без `sleep` в тестах — только `XCTestExpectation` + `wait(for:timeout:)`.

---

## File Structure

- `/covey/Sources/CoveyKit/Protocol.swift` — `Request`, `ServerMessage`, `DaemonEvent` (Codable).
- `/covey/Sources/CoveydCore/ScrollbackBuffer.swift` — ПЕРЕПИСАТЬ эвикцию на кольцо (#3).
- `/covey/Sources/CoveydCore/SessionRegistry.swift` — РАСШИРИТЬ: `onSessionAdded`/`onSessionRemoved`, `rename`, `backfill`.
- `/covey/Sources/CoveydCore/NDJSONCodec.swift` — `LineFramer` + `encodeLine`.
- `/covey/Sources/CoveydCore/Connection.swift` — `ClientSink` + `Connection` (типизированный endpoint над fd).
- `/covey/Sources/CoveydCore/SocketServer.swift` — POSIX UDS listen/accept.
- `/covey/Sources/CoveydCore/IPCServer.swift` — диспетчер + брокер.
- `/covey/Sources/coveyd/main.swift` — entry point.
- Тесты: `Tests/CoveyKitTests/ProtocolTests.swift`, `Tests/CoveydCoreTests/{NDJSONCodecTests,SocketServerTests,IPCServerTests}.swift`, дополнения к `ScrollbackBufferTests`/`SessionRegistryTests`, хелпер в `Tests/CoveydCoreTests/TestSupport.swift`.

---

### Task 1: Протокол (CoveyKit)

**Files:**
- Create: `/covey/Sources/CoveyKit/Protocol.swift`
- Test: `/covey/Tests/CoveyKitTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: `Session` (Slice 1).
- Produces:
  - `struct Request: Codable, Equatable { var id: Int; var op: Op }`
  - `enum Request.Op: Codable, Equatable` — cases: `list`, `create(dir:String, agent:String, argv:[String]?, name:String?)`, `kill(name:String)`, `rename(name:String, newName:String)`, `attach(name:String, sinceSeq:Int?)`, `detach(name:String)`, `input(name:String, bytesB64:String)`, `resize(name:String, cols:UInt16, rows:UInt16)`
  - `enum ServerMessage: Codable, Equatable { case response(id:Int, result:Result); case event(DaemonEvent) }`
  - `enum ServerMessage.Result: Codable, Equatable { case ok; case session(Session); case sessions([Session]); case error(code:String, message:String) }`
  - `enum DaemonEvent: Codable, Equatable { case output(name:String, seq:Int, bytesB64:String); case sessionAdded(session:Session); case sessionRemoved(name:String); case exited(name:String, code:Int32) }`

- [ ] **Step 1: Написать типы** в `/covey/Sources/CoveyKit/Protocol.swift`

```swift
public struct Request: Codable, Equatable {
    public var id: Int
    public var op: Op

    public init(id: Int, op: Op) { self.id = id; self.op = op }

    public enum Op: Codable, Equatable {
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

public enum ServerMessage: Codable, Equatable {
    case response(id: Int, result: Result)
    case event(DaemonEvent)

    public enum Result: Codable, Equatable {
        case ok
        case session(Session)
        case sessions([Session])
        case error(code: String, message: String)
    }
}

public enum DaemonEvent: Codable, Equatable {
    case output(name: String, seq: Int, bytesB64: String)
    case sessionAdded(session: Session)
    case sessionRemoved(name: String)
    case exited(name: String, code: Int32)
}
```

- [ ] **Step 2: Написать тесты** в `/covey/Tests/CoveyKitTests/ProtocolTests.swift`

```swift
import XCTest
@testable import CoveyKit

final class ProtocolTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(value, back)
    }

    func testRequestOpRoundTrip() throws {
        let ops: [Request.Op] = [
            .list,
            .create(dir: "/work", agent: "claude", argv: ["claude"], name: nil),
            .kill(name: "s-1"),
            .rename(name: "a", newName: "b"),
            .attach(name: "s-1", sinceSeq: 42),
            .detach(name: "s-1"),
            .input(name: "s-1", bytesB64: "aGk="),
            .resize(name: "s-1", cols: 80, rows: 24),
        ]
        for op in ops { try roundTrip(Request(id: 7, op: op)) }
    }

    func testServerMessageRoundTrip() throws {
        let s = Session(name: "s-1", dir: "/w", cwd: "/w", agent: "claude", created: 1)
        let msgs: [ServerMessage] = [
            .response(id: 1, result: .ok),
            .response(id: 2, result: .session(s)),
            .response(id: 3, result: .sessions([s])),
            .response(id: 4, result: .error(code: "notFound", message: "no such session")),
            .event(.output(name: "s-1", seq: 5, bytesB64: "aGk=")),
            .event(.sessionAdded(session: s)),
            .event(.sessionRemoved(name: "s-1")),
            .event(.exited(name: "s-1", code: 0)),
        ]
        for m in msgs { try roundTrip(m) }
    }

    func testGoldenWireFormat() throws {
        let line = { (v: Request) in String(decoding: try self.encoder().encode(v), as: UTF8.self) }
        XCTAssertEqual(try line(Request(id: 1, op: .list)),
                       #"{"id":1,"op":{"list":{}}}"#)
        XCTAssertEqual(try line(Request(id: 2, op: .kill(name: "s-1"))),
                       #"{"id":2,"op":{"kill":{"name":"s-1"}}}"#)
        // nil optionals are omitted:
        XCTAssertEqual(try line(Request(id: 3, op: .create(dir: "/w", agent: "claude", argv: nil, name: nil))),
                       #"{"id":3,"op":{"create":{"agent":"claude","dir":"/w"}}}"#)
    }
}
```

- [ ] **Step 3: Запустить — зелёный**

Run: `swift test --filter ProtocolTests`
Expected: PASS (3 теста). Это чистые data-типы, отдельный «красный» шаг не нужен — round-trip и golden проверяют корректность сразу. Если golden-строка не совпала, сверь точный вывод и поправь ожидаемую строку (порядок ключей — алфавитный из-за `.sortedKeys`).

- [ ] **Step 4: Commit**

```bash
git add Sources/CoveyKit/Protocol.swift Tests/CoveyKitTests/ProtocolTests.swift
git commit -m "feat(coveykit): IPC protocol types (Request/ServerMessage/DaemonEvent)"
```

---

### Task 2: #3 — кольцевой ScrollbackBuffer

**Files:**
- Modify: `/covey/Sources/CoveydCore/ScrollbackBuffer.swift` (переписать внутренности)
- Test: `/covey/Tests/CoveydCoreTests/ScrollbackBufferTests.swift` (добавить wrap-тест)

**Interfaces:**
- Produces: тот же публичный API — `init(limit:)`, `headSeq`, `tailSeq`, `append(_:) -> (from:Int, to:Int)`, `since(_:) -> (bytes:[UInt8], fromSeq:Int, gapped:Bool)`. Поведение идентично; меняется только сложность эвикции.

> Это **рефакторинг**, а не новое поведение: TDD-«красный» не применим. Страховка — существующие 5 тестов + новый wrap-тест; переписываем реализацию, все должны остаться зелёными.

- [ ] **Step 1: Добавить wrap-тест** в `ScrollbackBufferTests.swift` (внутри класса)

```swift
    func testSinceReadsAcrossRingWrap() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(bytes("ab"))
        b.append(bytes("cd"))
        b.append(bytes("ef")) // ring now holds "cdef", head=2, tail=6
        XCTAssertEqual(b.headSeq, 2)
        XCTAssertEqual(b.tailSeq, 6)
        let got = b.since(2)
        XCTAssertEqual(got.bytes, bytes("cdef"))
        XCTAssertEqual(got.fromSeq, 2)
        XCTAssertFalse(got.gapped)
    }
```

- [ ] **Step 2: Запустить — зелёный на текущей (массивной) реализации**

Run: `swift test --filter ScrollbackBufferTests`
Expected: PASS (6 тестов). Старая реализация хранит непрерывный массив, поэтому wrap-тест тоже проходит — это нормально, он страхует НОВЫЙ код-путь.

- [ ] **Step 3: Переписать реализацию на кольцо** — заменить тело `/covey/Sources/CoveydCore/ScrollbackBuffer.swift`

```swift
/// A bounded ring buffer of raw PTY output, addressed by an absolute byte
/// sequence number (`seq`). Eviction is O(1): bytes are overwritten in place.
public final class ScrollbackBuffer {
    /// `seq` of the oldest byte still available.
    public private(set) var headSeq = 0
    /// `seq` one past the last byte ever appended.
    public private(set) var tailSeq = 0

    private var storage: [UInt8]
    private var count = 0
    private let capacity: Int

    public init(limit: Int) {
        capacity = max(1, limit)
        storage = [UInt8](repeating: 0, count: capacity)
    }

    @discardableResult
    public func append(_ bytes: [UInt8]) -> (from: Int, to: Int) {
        let from = tailSeq
        // Write every byte at its absolute position (seq % capacity). If the chunk is
        // larger than capacity, earlier bytes are simply overwritten — only the last
        // `capacity` survive, at the correct positions. O(bytes.count), no array shift.
        for byte in bytes {
            storage[tailSeq % capacity] = byte
            tailSeq += 1
        }
        count = min(count + bytes.count, capacity)
        headSeq = tailSeq - count
        return (from, tailSeq)
    }

    public func since(_ seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool) {
        let gapped = seq < headSeq
        let effective = max(seq, headSeq)
        if effective >= tailSeq { return ([], tailSeq, gapped) }
        let length = tailSeq - effective
        var out = [UInt8]()
        out.reserveCapacity(length)
        var idx = effective % capacity
        for _ in 0..<length {
            out.append(storage[idx])
            idx += 1
            if idx == capacity { idx = 0 }
        }
        return (out, effective, gapped)
    }
}
```

Note про `append`: каждый байт пишется по `tailSeq % capacity`, `tailSeq` растёт на каждый байт (seq абсолютный). Если чанк больше `capacity` — ранние байты затрутся поздними, выживут последние `capacity` на правильных позициях. `count = min(count + bytes.count, capacity)`, `headSeq = tailSeq - count`.

- [ ] **Step 4: Запустить — все зелёные**

Run: `swift test --filter ScrollbackBufferTests`
Expected: PASS (6 тестов) на новой кольцевой реализации.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoveydCore/ScrollbackBuffer.swift Tests/CoveydCoreTests/ScrollbackBufferTests.swift
git commit -m "perf(coveydcore): ring-buffer scrollback with O(1) eviction"
```

---

### Task 3: SessionRegistry — события, rename, backfill

**Files:**
- Modify: `/covey/Sources/CoveydCore/SessionRegistry.swift`
- Test: `/covey/Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `Session` (CoveyKit), `PTYProcess.backfill` (Slice 1).
- Produces (добавляется к существующему API):
  - `var onSessionAdded: ((Session) -> Void)?`
  - `var onSessionRemoved: ((String) -> Void)?`
  - `func rename(name: String, newName: String) throws` — бросает `RegistryError.notFound(name)` / `.duplicateName(newName)`
  - `func backfill(name: String, since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)?`
  - `create` теперь дёргает `onSessionAdded(session)` после вставки.

- [ ] **Step 1: Написать тесты** (добавить в `SessionRegistryTests.swift`)

```swift
    func testCreateFiresSessionAdded() throws {
        let reg = SessionRegistry(clock: { 1 })
        let added = expectation(description: "added")
        reg.onSessionAdded = { _ in added.fulfill() }
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        wait(for: [added], timeout: 5)
        reg.kill(name: s.name)
    }

    func testRenameMovesEntryAndFiresEvents() throws {
        let reg = SessionRegistry()
        let removed = expectation(description: "removed")
        let added = expectation(description: "added")
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "old")
        reg.onSessionRemoved = { name in if name == "old" { removed.fulfill() } }
        reg.onSessionAdded = { sess in if sess.name == "new" { added.fulfill() } }
        try reg.rename(name: "old", newName: "new")
        wait(for: [removed, added], timeout: 5)
        XCTAssertNil(reg.get(name: "old"))
        XCTAssertEqual(reg.get(name: "new")?.name, "new")
        reg.kill(name: "new")
    }

    func testRenameUnknownThrowsNotFound() throws {
        let reg = SessionRegistry()
        XCTAssertThrowsError(try reg.rename(name: "ghost", newName: "x")) {
            XCTAssertEqual($0 as? RegistryError, .notFound("ghost"))
        }
    }

    func testRenameToTakenThrowsDuplicate() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "a")
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "b")
        XCTAssertThrowsError(try reg.rename(name: "a", newName: "b")) {
            XCTAssertEqual($0 as? RegistryError, .duplicateName("b"))
        }
        reg.kill(name: "a"); reg.kill(name: "b")
    }

    func testBackfillReturnsNilForUnknown() throws {
        let reg = SessionRegistry()
        XCTAssertNil(reg.backfill(name: "ghost", since: 0))
    }
```

- [ ] **Step 2: Запустить — красный**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — `value of type 'SessionRegistry' has no member 'onSessionAdded'` / `'rename'` / `'backfill'`.

- [ ] **Step 3: Реализовать** — изменения в `/covey/Sources/CoveydCore/SessionRegistry.swift`

Добавить свойства рядом с `onExit`:
```swift
    public var onSessionAdded: ((Session) -> Void)?
    public var onSessionRemoved: ((String) -> Void)?
```

В `create`, после `entries[id] = (session, proc)` и до `lock.unlock()`, ничего не вызываем под локом; вместо этого после `lock.unlock()` и перед `return session` добавить:
```swift
        onSessionAdded?(session)
        return session
```
(то есть `lock.unlock()` — затем `onSessionAdded?(session)` — затем `return`; колбэк вне лока, чтобы не держать лок во время внешнего кода.)

Добавить методы:
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
        lock.unlock()
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
    }

    public func backfill(name: String, since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)? {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        return proc?.backfill(since: seq)
    }
```

- [ ] **Step 4: Запустить — зелёный**

Run: `swift test --filter SessionRegistryTests`
Expected: PASS (существующие 4 + новые 5 = 9 тестов).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(coveydcore): registry add/remove events, rename, backfill"
```

---

### Task 4: NDJSONCodec (кадрирование)

**Files:**
- Create: `/covey/Sources/CoveydCore/NDJSONCodec.swift`
- Test: `/covey/Tests/CoveydCoreTests/NDJSONCodecTests.swift`

**Interfaces:**
- Produces:
  - `enum NDJSONError: Error, Equatable { case lineTooLong }`
  - `enum NDJSON { static func encodeLine<T: Encodable>(_ value: T) throws -> [UInt8]; static let decoder: JSONDecoder }`
  - `struct LineFramer { init(maxLineLength: Int = 4_000_000); mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] }` — возвращает завершённые строки (без `\n`); бросает `NDJSONError.lineTooLong`.

- [ ] **Step 1: Скелет** `/covey/Sources/CoveydCore/NDJSONCodec.swift`

```swift
import Foundation

public enum NDJSONError: Error, Equatable {
    case lineTooLong
}

public enum NDJSON {
    public static let decoder = JSONDecoder()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> [UInt8] {
        fatalError("not implemented")
    }
}

public struct LineFramer {
    private let maxLineLength: Int
    private var buffer: [UInt8] = []

    public init(maxLineLength: Int = 4_000_000) {
        self.maxLineLength = maxLineLength
    }

    public mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        fatalError("not implemented")
    }
}
```

- [ ] **Step 2: Тесты** `/covey/Tests/CoveydCoreTests/NDJSONCodecTests.swift`

```swift
import XCTest
@testable import CoveydCore

final class NDJSONCodecTests: XCTestCase {
    func testEncodeLineAppendsNewline() throws {
        let line = try NDJSON.encodeLine(["a": 1])
        XCTAssertEqual(line.last, 0x0A)                      // ends with '\n'
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"a\":1}\n")
    }

    func testFramerSplitsCompleteLines() throws {
        var f = LineFramer()
        let out = try f.feed(bytes("one\ntwo\n"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
    }

    func testFramerBuffersPartialLine() throws {
        var f = LineFramer()
        XCTAssertEqual(try f.feed(bytes("he")).count, 0)     // no newline yet
        let out = try f.feed(bytes("llo\n"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["hello"])
    }

    func testFramerHandlesMultipleAndTrailingPartial() throws {
        var f = LineFramer()
        let out = try f.feed(bytes("a\nb\nc"))
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        let rest = try f.feed(bytes("\n"))
        XCTAssertEqual(rest.map { String(decoding: $0, as: UTF8.self) }, ["c"])
    }

    func testFramerThrowsOnOverlongLine() {
        var f = LineFramer(maxLineLength: 4)
        XCTAssertThrowsError(try f.feed(bytes("abcde"))) {
            XCTAssertEqual($0 as? NDJSONError, .lineTooLong)
        }
    }
}
```

- [ ] **Step 3: Запустить — красный**

Run: `swift test --filter NDJSONCodecTests`
Expected: FAIL в рантайме на `fatalError("not implemented")`.

- [ ] **Step 4: Реализация** — заменить тела двух методов

`encodeLine`:
```swift
    public static func encodeLine<T: Encodable>(_ value: T) throws -> [UInt8] {
        var line = [UInt8](try encoder.encode(value))
        line.append(0x0A)   // '\n'
        return line
    }
```

`LineFramer.feed`:
```swift
    public mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                if buffer.count > maxLineLength { throw NDJSONError.lineTooLong }
            }
        }
        return lines
    }
```

- [ ] **Step 5: Запустить — зелёный**

Run: `swift test --filter NDJSONCodecTests`
Expected: PASS (5 тестов).

- [ ] **Step 6: Commit**

```bash
git add Sources/CoveydCore/NDJSONCodec.swift Tests/CoveydCoreTests/NDJSONCodecTests.swift
git commit -m "feat(coveydcore): NDJSON line framing + encoder"
```

---

### Task 5: Транспорт — SocketServer + Connection

**Files:**
- Create: `/covey/Sources/CoveydCore/Connection.swift`
- Create: `/covey/Sources/CoveydCore/SocketServer.swift`
- Modify: `/covey/Tests/CoveydCoreTests/TestSupport.swift` (хелпер `IPCTestClient`)
- Test: `/covey/Tests/CoveydCoreTests/SocketServerTests.swift`

**Interfaces:**
- Consumes: `Request`, `ServerMessage` (CoveyKit), `NDJSON`, `LineFramer` (Task 4).
- Produces:
  - `protocol ClientSink: AnyObject { var id: Int { get }; func send(_ message: ServerMessage) }`
  - `final class Connection: ClientSink` — `init(fd: Int32, id: Int)`, `var onRequest: ((Request, Connection) -> Void)?`, `var onBadRequest: ((Int?, Connection) -> Void)?`, `var onClose: ((Connection) -> Void)?`, `func start()`, `func send(_ message: ServerMessage)`, `func close()`
  - `final class SocketServer` — `init(path: String)`, `var onAccept: ((Connection) -> Void)?`, `func start() throws`, `func stop()`
  - `enum SocketError: Error { case socketFailed(Int32); case bindFailed(Int32); case listenFailed(Int32); case alreadyRunning }`

> Connection — типизированный endpoint: входящие строки декодирует двухшаговым декодом (`{id}` → полный `Request`), исходящие `ServerMessage` кодирует. Каждое чтение/запись — на собственной serial-очереди соединения.

- [ ] **Step 1: Скелеты** обоих файлов

`/covey/Sources/CoveydCore/Connection.swift`:
```swift
import Foundation

public protocol ClientSink: AnyObject {
    var id: Int { get }
    func send(_ message: ServerMessage)
}

public final class Connection: ClientSink {
    public let id: Int
    public var onRequest: ((Request, Connection) -> Void)?
    public var onBadRequest: ((Int?, Connection) -> Void)?
    public var onClose: ((Connection) -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var closed = false

    public init(fd: Int32, id: Int) {
        self.fd = fd
        self.id = id
        self.queue = DispatchQueue(label: "covey.conn.\(id)")
    }

    public func start() { fatalError("not implemented") }
    public func send(_ message: ServerMessage) { fatalError("not implemented") }
    public func close() { fatalError("not implemented") }
}
```

(добавь `import CoveyKit`? — `Request`/`ServerMessage` в CoveyKit; если CoveydCore уже импортирует CoveyKit в других файлах per-file импорт всё равно нужен здесь.) Добавь `import CoveyKit` сверху.

`/covey/Sources/CoveydCore/SocketServer.swift`:
```swift
import Foundation

public enum SocketError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
}

public final class SocketServer {
    public var onAccept: ((Connection) -> Void)?

    private let path: String
    private let queue = DispatchQueue(label: "covey.listener")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var nextConnID = 0

    public init(path: String) { self.path = path }

    public func start() throws { fatalError("not implemented") }
    public func stop() { fatalError("not implemented") }
}
```

- [ ] **Step 2: Хелпер `IPCTestClient`** — добавить в `/covey/Tests/CoveydCoreTests/TestSupport.swift`

```swift
import Foundation

/// Minimal blocking client over a unix-domain socket, for end-to-end tests.
final class IPCTestClient {
    private let fd: Int32

    init(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
                    strlcpy($0, src, MemoryLayout.size(ofValue: addr.sun_path))
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
    }

    func sendLine(_ s: String) {
        var data = Array(s.utf8); data.append(0x0A)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads until a full line (`\n`) is available; returns it without the newline.
    func readLine() -> String {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            line.append(byte)
        }
        return String(decoding: line, as: UTF8.self)
    }

    func close() { Darwin.close(fd) }
}
```

- [ ] **Step 3: Тесты транспорта** `/covey/Tests/CoveydCoreTests/SocketServerTests.swift`

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class SocketServerTests: XCTestCase {
    private func tempSocketPath() -> String {
        "\(NSTemporaryDirectory())covey-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    func testEchoRequestRoundTrip() throws {
        let path = tempSocketPath()
        let server = SocketServer(path: path)
        let connected = expectation(description: "request received")
        server.onAccept = { conn in
            conn.onRequest = { req, c in
                connected.fulfill()
                c.send(.response(id: req.id, result: .ok))   // echo an ok
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }

        let client = IPCTestClient(path: path)
        defer { client.close() }
        client.sendLine(#"{"id":7,"op":{"list":{}}}"#)
        wait(for: [connected], timeout: 5)

        let reply = client.readLine()
        let msg = try NDJSON.decoder.decode(ServerMessage.self, from: Data(reply.utf8))
        XCTAssertEqual(msg, .response(id: 7, result: .ok))
    }

    func testBadRequestReportsId() throws {
        let path = tempSocketPath()
        let server = SocketServer(path: path)
        let bad = expectation(description: "bad request")
        server.onAccept = { conn in
            conn.onBadRequest = { id, _ in
                XCTAssertEqual(id, 9)
                bad.fulfill()
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }

        let client = IPCTestClient(path: path)
        defer { client.close() }
        client.sendLine(#"{"id":9,"op":{"bogus":{}}}"#)  // valid id, invalid op
        wait(for: [bad], timeout: 5)
    }
}
```

- [ ] **Step 4: Запустить — красный**

Run: `swift test --filter SocketServerTests`
Expected: FAIL в рантайме на `fatalError` (start/send/... не реализованы).

- [ ] **Step 5: Реализовать `Connection`** — заменить три метода + добавить приватные хелперы

```swift
    public func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            Darwin.close(self.fd)
        }
        readSource = src
        src.resume()
    }

    public func send(_ message: ServerMessage) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard let line = try? NDJSON.encodeLine(message) else { return }
            line.withUnsafeBytes { raw in
                guard var base = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let n = write(self.fd, base, remaining)
                    if n > 0 { base = base.advanced(by: n); remaining -= n }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.readSource?.cancel()
            self.onClose?(self)
        }
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            let chunk = Array(buf[0..<n])
            let lines: [[UInt8]]
            do { lines = try framer.feed(chunk) }
            catch { onBadRequest?(nil, self); close(); return }
            for line in lines { dispatchLine(line) }
        } else {
            close()
        }
    }

    private func dispatchLine(_ line: [UInt8]) {
        let data = Data(line)
        struct Header: Decodable { let id: Int }
        if let req = try? NDJSON.decoder.decode(Request.self, from: data) {
            onRequest?(req, self)
        } else {
            let id = (try? NDJSON.decoder.decode(Header.self, from: data))?.id
            onBadRequest?(id, self)
        }
    }
```

- [ ] **Step 6: Реализовать `SocketServer`** — заменить `start`/`stop` + хелпер

```swift
    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
                    strlcpy($0, src, MemoryLayout.size(ofValue: addr.sun_path))
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindOK == 0 else { Darwin.close(fd); throw SocketError.bindFailed(errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { Darwin.close(fd); throw SocketError.listenFailed(errno) }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD); self.listenFD = -1
        }
        acceptSource = src
        src.resume()
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptSource?.cancel()
            unlink(self.path)
        }
    }

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        nextConnID += 1
        let conn = Connection(fd: clientFD, id: nextConnID)
        onAccept?(conn)
    }
```

- [ ] **Step 7: Запустить — зелёный**

Run: `swift test --filter SocketServerTests`
Expected: PASS (2 теста). Если флейк по таймауту — перезапусти; тут реальный сокет.

- [ ] **Step 8: Commit**

```bash
git add Sources/CoveydCore/Connection.swift Sources/CoveydCore/SocketServer.swift Tests/CoveydCoreTests/SocketServerTests.swift Tests/CoveydCoreTests/TestSupport.swift
git commit -m "feat(coveydcore): POSIX unix-socket server + typed connection"
```

---

### Task 6: IPCServer — диспетчер, подписки, фан-аут

**Files:**
- Create: `/covey/Sources/CoveydCore/IPCServer.swift`
- Test: `/covey/Tests/CoveydCoreTests/IPCServerTests.swift`

**Interfaces:**
- Consumes: `SessionRegistry` (Task 3), `Request`/`ServerMessage`/`DaemonEvent` (Task 1), `ClientSink` (Task 5).
- Produces:
  - `final class IPCServer` — `init(registry: SessionRegistry)`, `func register(_ sink: ClientSink)`, `func unregister(_ sink: ClientSink)`, `func handle(_ request: Request, from sink: ClientSink)`, `func handleBadRequest(id: Int?, from sink: ClientSink)`
  - Внутри: серийная очередь `server`, набор `sinks: [Int: ClientSink]`, подписки `subscribers: [String: Set<Int>]`. В `init` подписывается на `registry.onSessionAdded/onSessionRemoved/onExit` и делает broadcast.
  - **#4 notFound**: `kill/input/resize/attach/detach/rename` для имени, которого нет (`registry.get(name:) == nil`), → `.error(code: "notFound", …)`.

- [ ] **Step 1: Скелет** `/covey/Sources/CoveydCore/IPCServer.swift`

```swift
import Foundation
import CoveyKit

public final class IPCServer {
    private let registry: SessionRegistry
    private let server = DispatchQueue(label: "covey.ipc")
    private var sinks: [Int: ClientSink] = [:]
    private var subscribers: [String: Set<Int>] = [:]

    public init(registry: SessionRegistry) {
        self.registry = registry
        fatalError("not implemented")   // wire registry callbacks
    }

    public func register(_ sink: ClientSink) { fatalError("not implemented") }
    public func unregister(_ sink: ClientSink) { fatalError("not implemented") }
    public func handle(_ request: Request, from sink: ClientSink) { fatalError("not implemented") }
    public func handleBadRequest(id: Int?, from sink: ClientSink) { fatalError("not implemented") }
}
```

- [ ] **Step 2: Фейковый sink + тесты** `/covey/Tests/CoveydCoreTests/IPCServerTests.swift`

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class FakeSink: ClientSink {
    let id: Int
    private let lock = NSLock()
    private var messages: [ServerMessage] = []
    init(id: Int) { self.id = id }
    func send(_ message: ServerMessage) { lock.lock(); messages.append(message); lock.unlock() }
    var captured: [ServerMessage] { lock.lock(); defer { lock.unlock() }; return messages }
}

final class IPCServerTests: XCTestCase {
    private func waitUntil(_ cond: @escaping () -> Bool, _ desc: String) {
        let exp = expectation(description: desc)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { if cond() { timer.cancel(); exp.fulfill() } }
        timer.resume()
        wait(for: [exp], timeout: 5)
    }

    func testCreateReturnsSessionAndBroadcastsAdded() {
        let server = IPCServer(registry: SessionRegistry(clock: { 1 }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 10, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1")), from: sink)
        waitUntil({ sink.captured.contains { if case .response(10, .session) = $0 { return true }; return false } }, "create response")
        waitUntil({ sink.captured.contains { if case .event(.sessionAdded) = $0 { return true }; return false } }, "added event")
        server.handle(Request(id: 11, op: .kill(name: "s1")), from: sink)
    }

    func testUnknownNameReturnsNotFound() {
        let server = IPCServer(registry: SessionRegistry())
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 5, op: .kill(name: "ghost")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(5, .error(let code, _)) = $0 { return code == "notFound" }; return false
        } }, "notFound error")
    }

    func testAttachStreamsBackfillAndLiveOutput() {
        let server = IPCServer(registry: SessionRegistry())
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1")), from: sink)
        server.handle(Request(id: 2, op: .attach(name: "s1", sinceSeq: nil)), from: sink)
        server.handle(Request(id: 3, op: .input(name: "s1", bytesB64: Data("ping\n".utf8).base64EncodedString())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .event(.output(_, _, let b64)) = $0,
               let d = Data(base64Encoded: b64) { return String(decoding: d, as: UTF8.self).contains("ping") }
            return false
        } }, "live output")
        server.handle(Request(id: 4, op: .kill(name: "s1")), from: sink)
    }
}
```

- [ ] **Step 3: Запустить — красный**

Run: `swift test --filter IPCServerTests`
Expected: FAIL в рантайме на `fatalError` в `init`/методах.

- [ ] **Step 4: Реализация** — заменить тела в `IPCServer.swift`

```swift
    public init(registry: SessionRegistry) {
        self.registry = registry
        registry.onSessionAdded = { [weak self] s in self?.broadcast(.event(.sessionAdded(session: s))) }
        registry.onSessionRemoved = { [weak self] name in self?.broadcast(.event(.sessionRemoved(name: name))) }
        registry.onExit = { [weak self] name, code in
            guard let self else { return }
            self.broadcast(.event(.exited(name: name, code: code)))
            self.server.async { self.subscribers[name] = nil }
        }
    }

    public func register(_ sink: ClientSink) {
        server.async { [weak self] in self?.sinks[sink.id] = sink }
    }

    public func unregister(_ sink: ClientSink) {
        server.async { [weak self] in
            guard let self else { return }
            self.sinks[sink.id] = nil
            for name in self.subscribers.keys { self.subscribers[name]?.remove(sink.id) }
        }
    }

    public func handleBadRequest(id: Int?, from sink: ClientSink) {
        sink.send(.response(id: id ?? 0, result: .error(code: "badRequest", message: "malformed request")))
    }

    public func handle(_ request: Request, from sink: ClientSink) {
        server.async { [weak self] in self?.dispatch(request, sink) }
    }

    // MARK: - private (all on `server` queue)

    private func broadcast(_ message: ServerMessage) {
        server.async { [weak self] in
            guard let self else { return }
            for sink in self.sinks.values { sink.send(message) }
        }
    }

    private func dispatch(_ request: Request, _ sink: ClientSink) {
        let id = request.id
        func reply(_ r: ServerMessage.Result) { sink.send(.response(id: id, result: r)) }
        func notFound(_ name: String) { reply(.error(code: "notFound", message: "no session: \(name)")) }

        switch request.op {
        case .list:
            reply(.sessions(registry.list()))

        case let .create(dir, agent, argv, name):
            do {
                let s = try registry.create(dir: dir, agent: agent, argv: argv ?? [agent], name: name)
                attachOutputFanout(for: s.name)   // route this session's output to subscribers
                reply(.session(s))
            } catch let e as RegistryError {
                reply(errorResult(e))
            } catch {
                reply(.error(code: "spawnFailed", message: "\(error)"))
            }

        case let .kill(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            registry.kill(name: name); reply(.ok)

        case let .rename(name, newName):
            do { try registry.rename(name: name, newName: newName); reply(.ok) }
            catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "badRequest", message: "\(error)")) }

        case let .attach(name, sinceSeq):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name, default: []].insert(sink.id)
            if let bf = registry.backfill(name: name, since: sinceSeq ?? 0), !bf.bytes.isEmpty {
                sink.send(.event(.output(name: name, seq: bf.fromSeq,
                                         bytesB64: Data(bf.bytes).base64EncodedString())))
            }
            reply(.ok)

        case let .detach(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name]?.remove(sink.id); reply(.ok)

        case let .input(name, bytesB64):
            guard registry.get(name: name) != nil else { return notFound(name) }
            guard let data = Data(base64Encoded: bytesB64) else {
                return reply(.error(code: "badRequest", message: "invalid base64"))
            }
            registry.write(name: name, bytes: [UInt8](data)); reply(.ok)

        case let .resize(name, cols, rows):
            guard registry.get(name: name) != nil else { return notFound(name) }
            registry.resize(name: name, cols: cols, rows: rows); reply(.ok)
        }
    }

    private func attachOutputFanout(for name: String) {
        registry.attachOutput(name: name) { [weak self] bytes, seq in
            guard let self else { return }
            self.server.async {
                guard let subs = self.subscribers[name], !subs.isEmpty else { return }
                let msg = ServerMessage.event(.output(name: name, seq: seq,
                                                      bytesB64: Data(bytes).base64EncodedString()))
                for id in subs { self.sinks[id]?.send(msg) }
            }
        }
    }

    private func errorResult(_ e: RegistryError) -> ServerMessage.Result {
        switch e {
        case .notFound(let n):      return .error(code: "notFound", message: "no session: \(n)")
        case .duplicateName(let n): return .error(code: "duplicateName", message: "name taken: \(n)")
        }
    }
```

- [ ] **Step 5: Запустить — зелёный**

Run: `swift test --filter IPCServerTests`
Expected: PASS (3 теста).

- [ ] **Step 6: Commit**

```bash
git add Sources/CoveydCore/IPCServer.swift Tests/CoveydCoreTests/IPCServerTests.swift
git commit -m "feat(coveydcore): IPC dispatcher with subscriptions and output fan-out"
```

---

### Task 7: Entry point + end-to-end

**Files:**
- Modify: `/covey/Sources/coveyd/main.swift`
- Test: `/covey/Tests/CoveydCoreTests/EndToEndTests.swift`

**Interfaces:**
- Consumes: `SocketServer`, `IPCServer`, `SessionRegistry`, `Connection`, `IPCTestClient`.
- Produces: рабочий демон, слушающий путь сокета; в тестах — связка `SocketServer`+`IPCServer`+`SessionRegistry`.

- [ ] **Step 1: End-to-end тест** `/covey/Tests/CoveydCoreTests/EndToEndTests.swift`

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class EndToEndTests: XCTestCase {
    func testCreateAttachInputOutputKill() throws {
        let path = "\(NSTemporaryDirectory())covey-e2e-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        let ipc = IPCServer(registry: registry)
        let server = SocketServer(path: path)
        server.onAccept = { conn in
            ipc.register(conn)
            conn.onRequest = { req, c in ipc.handle(req, from: c) }
            conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
            conn.onClose = { c in ipc.unregister(c) }
            conn.start()
        }
        try server.start()
        defer { server.stop() }

        let client = IPCTestClient(path: path)
        defer { client.close() }

        func decode(_ s: String) throws -> ServerMessage {
            try NDJSON.decoder.decode(ServerMessage.self, from: Data(s.utf8))
        }

        client.sendLine(#"{"id":1,"op":{"create":{"dir":"/usr","agent":"sh","argv":["/bin/cat"],"name":"s1"}}}"#)
        // create response + sessionAdded event arrive (order not guaranteed); read until we see the response.
        var sawCreate = false
        for _ in 0..<4 {
            if case .response(1, .session) = try decode(client.readLine()) { sawCreate = true; break }
        }
        XCTAssertTrue(sawCreate)

        client.sendLine(#"{"id":2,"op":{"attach":{"name":"s1"}}}"#)
        client.sendLine(#"{"id":3,"op":{"input":{"name":"s1","bytesB64":"cGluZwo="}}}"#)  // "ping\n"

        var sawPing = false
        for _ in 0..<10 {
            if case .event(.output(_, _, let b64)) = try decode(client.readLine()),
               let d = Data(base64Encoded: b64),
               String(decoding: d, as: UTF8.self).contains("ping") { sawPing = true; break }
        }
        XCTAssertTrue(sawPing)

        client.sendLine(#"{"id":9,"op":{"kill":{"name":"s1"}}}"#)
    }
}
```

- [ ] **Step 2: Запустить — красный**

Run: `swift test --filter EndToEndTests`
Expected: компилируется (все типы готовы), но может упасть/зависнуть, пока проводка верна. Если все Task 1–6 зелёные, этот тест должен пройти сразу — он лишь связывает готовые куски. Если падает — чини проводку (onAccept), не компоненты.

- [ ] **Step 3: Реализовать entry point** — заменить `/covey/Sources/coveyd/main.swift`

```swift
import Foundation
import CoveydCore

// Resolve ~/.covey/coveyd.sock
let home = FileManager.default.homeDirectoryForCurrentUser
let dir = home.appendingPathComponent(".covey", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let socketPath = dir.appendingPathComponent("coveyd.sock").path

// Single-instance: if an existing socket accepts a connection, another daemon is alive.
if FileManager.default.fileExists(atPath: socketPath) {
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
                strlcpy($0, src, MemoryLayout.size(ofValue: addr.sun_path))
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let alive = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } == 0
    }
    close(probe)
    if alive {
        FileHandle.standardError.write(Data("coveyd: already running at \(socketPath)\n".utf8))
        exit(1)
    }
    unlink(socketPath)   // stale socket
}

let registry = SessionRegistry()
let ipc = IPCServer(registry: registry)
let server = SocketServer(path: socketPath)
server.onAccept = { conn in
    ipc.register(conn)
    conn.onRequest = { req, c in ipc.handle(req, from: c) }
    conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
    conn.onClose = { c in ipc.unregister(c) }
    conn.start()
}

// Cleanup the socket file on termination. A signal(2) handler must be a context-free
// C function, so use DispatchSource signal sources (their closures may capture).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let onSignal: () -> Void = { unlink(socketPath); exit(0) }
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
termSource.setEventHandler(handler: onSignal)
intSource.setEventHandler(handler: onSignal)
termSource.resume()
intSource.resume()

do {
    try server.start()
    FileHandle.standardError.write(Data("coveyd: listening at \(socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("coveyd: failed to start: \(error)\n".utf8))
    exit(1)
}

dispatchMain()
```

- [ ] **Step 4: Запустить весь набор + сборка executable**

Run: `swift build && swift test`
Expected: build OK (включая `coveyd`); все тесты зелёные (Slice 1 + Slice 2).

- [ ] **Step 5: Commit**

```bash
git add Sources/coveyd/main.swift Tests/CoveydCoreTests/EndToEndTests.swift
git commit -m "feat(coveyd): wire socket server + IPC dispatcher entry point"
```

---

## Definition of Done (срез 2)
1. `swift build` + `swift test` зелёные.
2. Все наборы из §7 спеки проходят (Protocol, NDJSONCodec, ScrollbackBuffer+wrap, расширенный SessionRegistry, IPCServer, end-to-end сокет).
3. `coveyd` слушает `~/.covey/coveyd.sock`: клиент может create/list/kill/rename, attach стримит backfill+live output, kill даёт exited.
4. Неизвестное имя → `.error("notFound")` (#4).
5. `ScrollbackBuffer` — кольцевой, эвикция O(1) (#3).

## Следующий срез
Срез 3: status inference (`parse_prompt`/`content_hash`, событие `statusChanged`, статусы в `list`); затем CoveyKit `IPCClient` и SwiftUI-оболочка.
