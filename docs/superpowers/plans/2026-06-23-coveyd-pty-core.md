# coveyd PTY-ядро (Slice 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Метод работы в этом проекте (важно):** код пишет пользователь **руками** по шагам;
> ассистент даёт шаг, объясняет и ревьюит. **Все git-операции (init/add/commit) выполняет
> пользователь сам.** Шаги «Commit» в плане — это действия пользователя, а не ассистента.

**Goal:** Реализовать изолированное PTY-ядро демона `coveyd` (без IPC и UI): модели, ограниченный scrollback-буфер, один процесс в PTY и in-memory реестр сессий — всё под юнит-тестами.

**Architecture:** SwiftPM-пакет с тремя продуктовыми таргетами — `CoveyKit` (Codable-модели, общие с будущим клиентом), `CoveydCore` (ядро демона: буфер/процесс/реестр) и тонкий executable `coveyd`. Ядро оперирует сырыми байтами; вывод PTY читается через `DispatchSource`, складывается в ring-буфер с абсолютным байтовым `seq` и раздаётся через колбэки. Проверка — `swift test` (TDD), живая ручная проверка отложена до UI.

**Tech Stack:** Swift 6.3 / SwiftPM, `import Darwin` (`forkpty`, `ioctl`/`TIOCSWINSZ`, `waitpid`, `execvp`), GCD (`DispatchSource`, `DispatchQueue`), XCTest.

## Global Constraints

- Язык/тулчейн: Swift 6.3.2, `swift-tools-version: 6.2`. Каждый таргет — `swiftLanguageMode(.v5)` (отключаем строгую конкурентность Swift 6 на этом срезе).
- Платформа: `.macOS(.v26)` (enum `.v26` требует tools-version 6.2).
- Ядро **байт-прозрачно**: только `[UInt8]`, без интерпретации UTF-8/VT.
- В детях после `forkpty` — только async-signal-safe вызовы; все C-строки (argv, cwd) готовятся в родителе **до** `forkpty`.
- `seq` = абсолютное байтовое смещение от старта сессии.
- Без `sleep` в тестах — только `XCTestExpectation` + `wait(for:timeout:)`.
- Имена генерируются детерминированным счётчиком (без `Date`/random).
- Все git-команды выполняет пользователь вручную.

---

## File Structure

- `Package.swift` — манифест: таргеты `CoveyKit`, `CoveydCore`, `coveyd`, тесты.
- `Sources/CoveyKit/Models.swift` — `Session`, `GitInfo`, `Status` (Codable, public).
- `Sources/CoveydCore/ScrollbackBuffer.swift` — ограниченный ring-буфер + backfill.
- `Sources/CoveydCore/PTYProcess.swift` — один `forkpty`-процесс в PTY.
- `Sources/CoveydCore/SessionRegistry.swift` — реестр `name -> (Session, PTYProcess)`.
- `Sources/coveyd/main.swift` — заглушка точки входа (реальный запуск — срез 2).
- `Tests/CoveyKitTests/ModelsTests.swift` — round-trip моделей.
- `Tests/CoveydCoreTests/ScrollbackBufferTests.swift`
- `Tests/CoveydCoreTests/PTYProcessTests.swift`
- `Tests/CoveydCoreTests/SessionRegistryTests.swift`

---

### Task 1: Каркас пакета + модели CoveyKit

**Files:**
- Create: `Package.swift`
- Create: `Sources/CoveyKit/Models.swift`
- Create: `Sources/coveyd/main.swift`
- Test: `Tests/CoveyKitTests/ModelsTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public struct GitInfo: Codable, Equatable { var branch: String; var added: UInt32; var removed: UInt32 }`
  - `public struct Session: Codable, Equatable { var name, dir, cwd, agent: String; var created: Int64; var git: GitInfo?; var worktreeRepo: String? }`
  - `public enum Status: String, Codable, Equatable { case running, waiting, idle }`

- [ ] **Step 1: Создать `Package.swift`** (на этом срезе ссылается только на `CoveyKit` + `coveyd`; `CoveydCore` добавим в Task 2)

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "covey",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CoveyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "coveyd",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Создать заглушку `Sources/coveyd/main.swift`** (чтобы executable-таргет собирался)

```swift
import Foundation

// coveyd — точка входа демона. На срезе 1 рантайма нет;
// IPC-сервер и реальный запуск появятся в срезе 2.
FileHandle.standardError.write(Data("coveyd: no runtime yet (slice 1)\n".utf8))
```

- [ ] **Step 3: Написать падающий тест моделей** в `Tests/CoveyKitTests/ModelsTests.swift`

```swift
import XCTest
@testable import CoveyKit

final class ModelsTests: XCTestCase {
    func testSessionRoundTrip() throws {
        let s = Session(
            name: "s-1", dir: "/work", cwd: "/work", agent: "claude",
            created: 1_700_000_000,
            git: GitInfo(branch: "main", added: 3, removed: 1),
            worktreeRepo: "/repo"
        )
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testStatusRoundTrip() throws {
        for st in [Status.running, .waiting, .idle] {
            let data = try JSONEncoder().encode(st)
            XCTAssertEqual(try JSONDecoder().decode(Status.self, from: data), st)
        }
    }
}
```

- [ ] **Step 4: Запустить тест — убедиться, что не компилируется/падает**

Run: `swift test --filter ModelsTests`
Expected: FAIL — `cannot find 'Session' in scope` (моделей ещё нет).

- [ ] **Step 5: Реализовать `Sources/CoveyKit/Models.swift`**

```swift
public struct GitInfo: Codable, Equatable {
    public var branch: String
    public var added: UInt32
    public var removed: UInt32

    public init(branch: String, added: UInt32, removed: UInt32) {
        self.branch = branch
        self.added = added
        self.removed = removed
    }
}

public struct Session: Codable, Equatable {
    public var name: String
    public var dir: String
    public var cwd: String
    public var agent: String
    public var created: Int64
    public var git: GitInfo?
    public var worktreeRepo: String?

    public init(
        name: String, dir: String, cwd: String, agent: String,
        created: Int64, git: GitInfo? = nil, worktreeRepo: String? = nil
    ) {
        self.name = name
        self.dir = dir
        self.cwd = cwd
        self.agent = agent
        self.created = created
        self.git = git
        self.worktreeRepo = worktreeRepo
    }
}

public enum Status: String, Codable, Equatable {
    case running, waiting, idle
}
```

- [ ] **Step 6: Запустить тесты — зелёные**

Run: `swift test --filter ModelsTests`
Expected: PASS (2 теста).

- [ ] **Step 7: Commit** (выполняет пользователь)

```bash
git add Package.swift Sources/CoveyKit/Models.swift Sources/coveyd/main.swift Tests/CoveyKitTests/ModelsTests.swift
git commit -m "feat(coveykit): package skeleton + Session/GitInfo/Status models"
```

---

### Task 2: ScrollbackBuffer (ring-буфер + backfill)

**Files:**
- Modify: `Package.swift` (добавить таргет `CoveydCore` + тест-таргет `CoveydCoreTests`)
- Create: `Sources/CoveydCore/ScrollbackBuffer.swift`
- Test: `Tests/CoveydCoreTests/ScrollbackBufferTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public final class ScrollbackBuffer`
    - `public init(limit: Int)`
    - `public private(set) var headSeq: Int` — seq самого старого доступного байта
    - `public private(set) var tailSeq: Int` — seq, следующий за последним
    - `@discardableResult public func append(_ bytes: [UInt8]) -> (from: Int, to: Int)`
    - `public func since(_ seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)`

- [ ] **Step 1: Обновить `Package.swift`** — добавить `CoveydCore` и `CoveydCoreTests`

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "covey",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CoveyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoveydCore",
            dependencies: ["CoveyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "coveyd",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveyKitTests",
            dependencies: ["CoveyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoveydCoreTests",
            dependencies: ["CoveydCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Написать падающие тесты** в `Tests/CoveydCoreTests/ScrollbackBufferTests.swift`

```swift
import XCTest
@testable import CoveydCore

final class ScrollbackBufferTests: XCTestCase {
    func testAppendAdvancesTailAndSinceZeroReturnsAll() {
        let b = ScrollbackBuffer(limit: 1024)
        let r = b.append(Array("hello".utf8))
        XCTAssertEqual(r.from, 0)
        XCTAssertEqual(r.to, 5)
        XCTAssertEqual(b.tailSeq, 5)
        let got = b.since(0)
        XCTAssertEqual(got.bytes, Array("hello".utf8))
        XCTAssertEqual(got.fromSeq, 0)
        XCTAssertFalse(got.gapped)
    }

    func testSinceFromMiddle() {
        let b = ScrollbackBuffer(limit: 1024)
        b.append(Array("abcdef".utf8))
        let got = b.since(2)
        XCTAssertEqual(got.bytes, Array("cdef".utf8))
        XCTAssertEqual(got.fromSeq, 2)
        XCTAssertFalse(got.gapped)
    }

    func testOverflowEvictsAndAdvancesHead() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(Array("abcdef".utf8)) // оставляет последние 4: "cdef"
        XCTAssertEqual(b.headSeq, 2)
        XCTAssertEqual(b.tailSeq, 6)
        XCTAssertEqual(b.since(2).bytes, Array("cdef".utf8))
    }

    func testSinceEvictedSeqIsGapped() {
        let b = ScrollbackBuffer(limit: 4)
        b.append(Array("abcdef".utf8)) // head уехал на 2
        let got = b.since(0)
        XCTAssertTrue(got.gapped)
        XCTAssertEqual(got.fromSeq, 2)
        XCTAssertEqual(got.bytes, Array("cdef".utf8))
    }

    func testEmptyAndBeyondTail() {
        let b = ScrollbackBuffer(limit: 16)
        XCTAssertEqual(b.since(0).bytes, [])
        b.append(Array("xy".utf8))
        let got = b.since(10)
        XCTAssertEqual(got.bytes, [])
        XCTAssertEqual(got.fromSeq, 2)
        XCTAssertFalse(got.gapped)
    }
}
```

- [ ] **Step 3: Запустить тесты — убедиться, что падают**

Run: `swift test --filter ScrollbackBufferTests`
Expected: FAIL — `cannot find 'ScrollbackBuffer' in scope`.

- [ ] **Step 4: Реализовать `Sources/CoveydCore/ScrollbackBuffer.swift`**

```swift
/// Ограниченный ring-буфер сырого вывода PTY с абсолютной байтовой нумерацией (seq).
/// Поздно подключившийся клиент может запросить backfill через `since`.
public final class ScrollbackBuffer {
    public private(set) var headSeq: Int = 0   // seq первого доступного байта
    public private(set) var tailSeq: Int = 0   // seq, следующий за последним

    private var storage: [UInt8] = []
    private let limit: Int

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Добавляет байты, возвращает их диапазон seq [from, to).
    @discardableResult
    public func append(_ bytes: [UInt8]) -> (from: Int, to: Int) {
        let from = tailSeq
        storage.append(contentsOf: bytes)
        tailSeq += bytes.count
        if storage.count > limit {
            let drop = storage.count - limit
            storage.removeFirst(drop)
            headSeq += drop
        }
        return (from, tailSeq)
    }

    /// Возвращает байты начиная с `seq`. Если `seq` уже вытеснен — отдаёт доступный
    /// хвост и помечает `gapped = true` (был разрыв истории).
    public func since(_ seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool) {
        let gapped = seq < headSeq
        let effective = max(seq, headSeq)
        if effective >= tailSeq {
            return ([], tailSeq, gapped)
        }
        let offset = effective - headSeq
        return (Array(storage[offset...]), effective, gapped)
    }
}
```

- [ ] **Step 5: Запустить тесты — зелёные**

Run: `swift test --filter ScrollbackBufferTests`
Expected: PASS (5 тестов).

- [ ] **Step 6: Commit** (пользователь)

```bash
git add Package.swift Sources/CoveydCore/ScrollbackBuffer.swift Tests/CoveydCoreTests/ScrollbackBufferTests.swift
git commit -m "feat(coveydcore): bounded scrollback buffer with seq backfill"
```

---

### Task 3: PTYProcess (один forkpty-процесс в PTY)

**Files:**
- Create: `Sources/CoveydCore/PTYProcess.swift`
- Test: `Tests/CoveydCoreTests/PTYProcessTests.swift`

**Interfaces:**
- Consumes: `ScrollbackBuffer` (Task 2).
- Produces:
  - `public final class PTYProcess`
    - `public init(scrollbackLimit: Int = 1_000_000)`
    - `public var onOutput: (([UInt8], Int) -> Void)?` — (байты, seq начала чанка)
    - `public var onExit: ((Int32) -> Void)?` — код выхода
    - `public func spawn(argv: [String], env: [String: String]? = nil, cwd: String? = nil, cols: UInt16, rows: UInt16) throws`
    - `public func write(_ bytes: [UInt8])`
    - `public func resize(cols: UInt16, rows: UInt16)`
    - `public func kill()`
    - `public func backfill(since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)`
  - `public enum PTYError: Error { case spawnFailed(Int32) }`
  - Поведение: `env` на этом срезе **наследуется** от демона (параметр зарезервирован);
    провал `execvp` в ребёнке → `_exit(127)` → `onExit(127)`; `spawn` бросает только при
    отрицательном результате самого `forkpty`.

- [ ] **Step 1: Написать падающие тесты** в `Tests/CoveydCoreTests/PTYProcessTests.swift`

```swift
import XCTest
@testable import CoveydCore

final class PTYProcessTests: XCTestCase {
    private func textContains(_ bytes: [UInt8], _ needle: String) -> Bool {
        String(decoding: bytes, as: UTF8.self).contains(needle)
    }

    func testEchoProducesOutputThenExitsZero() throws {
        let p = PTYProcess()
        let outExp = expectation(description: "output")
        outExp.assertForOverFulfill = false
        let exitExp = expectation(description: "exit")
        var collected = [UInt8]()
        var code: Int32 = -999
        p.onOutput = { bytes, _ in
            collected += bytes
            if self.textContains(collected, "hello") { outExp.fulfill() }
        }
        p.onExit = { c in code = c; exitExp.fulfill() }
        try p.spawn(argv: ["/bin/echo", "hello"], cols: 80, rows: 24)
        wait(for: [outExp, exitExp], timeout: 5)
        XCTAssertEqual(code, 0)
    }

    func testCatEchoesInputThenKill() throws {
        let p = PTYProcess()
        let echoExp = expectation(description: "echo")
        echoExp.assertForOverFulfill = false
        let exitExp = expectation(description: "exit")
        var collected = [UInt8]()
        p.onOutput = { bytes, _ in
            collected += bytes
            if self.textContains(collected, "ping") { echoExp.fulfill() }
        }
        p.onExit = { _ in exitExp.fulfill() }
        try p.spawn(argv: ["/bin/cat"], cols: 80, rows: 24)
        p.write(Array("ping\n".utf8))
        wait(for: [echoExp], timeout: 5)
        p.kill()
        wait(for: [exitExp], timeout: 5)
    }

    func testNonexistentBinaryExits127() throws {
        let p = PTYProcess()
        let exitExp = expectation(description: "exit")
        var code: Int32 = -1
        p.onExit = { code = $0; exitExp.fulfill() }
        try p.spawn(argv: ["/nonexistent/binary"], cols: 80, rows: 24)
        wait(for: [exitExp], timeout: 5)
        XCTAssertEqual(code, 127)
    }

    func testInitialWinsize() throws {
        let p = PTYProcess()
        let exp = expectation(description: "size")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.onOutput = { bytes, _ in
            collected += bytes
            if self.textContains(collected, "24 80") { exp.fulfill() }
        }
        try p.spawn(argv: ["/bin/sh", "-c", "stty size"], cols: 80, rows: 24)
        wait(for: [exp], timeout: 5)
    }

    func testResizeUpdatesWinsize() throws {
        let p = PTYProcess()
        let exp = expectation(description: "resized")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.onOutput = { bytes, _ in
            collected += bytes
            if self.textContains(collected, "40 100") { exp.fulfill() }
        }
        try p.spawn(argv: ["/bin/sh"], cols: 80, rows: 24)
        p.resize(cols: 100, rows: 40)
        p.write(Array("stty size\n".utf8))
        wait(for: [exp], timeout: 5)
        p.kill()
    }

    func testCwdIsRespected() throws {
        let p = PTYProcess()
        let exp = expectation(description: "pwd")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.onOutput = { bytes, _ in
            collected += bytes
            if self.textContains(collected, "/usr") { exp.fulfill() }
        }
        try p.spawn(argv: ["/bin/sh", "-c", "pwd"], cwd: "/usr", cols: 80, rows: 24)
        wait(for: [exp], timeout: 5)
    }
}
```

- [ ] **Step 2: Запустить тесты — убедиться, что падают**

Run: `swift test --filter PTYProcessTests`
Expected: FAIL — `cannot find 'PTYProcess' in scope`.

- [ ] **Step 3: Реализовать `Sources/CoveydCore/PTYProcess.swift`**

```swift
import Darwin
import Dispatch

public enum PTYError: Error {
    case spawnFailed(Int32)   // errno от forkpty
}

/// Владеет одним дочерним процессом в собственном PTY: спавн через forkpty,
/// чтение вывода через DispatchSource, запись ввода, resize, kill.
/// Байт-прозрачен: наружу отдаёт сырые `[UInt8]`.
public final class PTYProcess {
    public var onOutput: (([UInt8], Int) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private let buffer: ScrollbackBuffer
    private let queue = DispatchQueue(label: "covey.pty")
    private var readSource: DispatchSourceRead?
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var reaped = false

    public init(scrollbackLimit: Int = 1_000_000) {
        self.buffer = ScrollbackBuffer(limit: scrollbackLimit)
    }

    public func spawn(
        argv: [String], env: [String: String]? = nil, cwd: String? = nil,
        cols: UInt16, rows: UInt16
    ) throws {
        precondition(pid == -1, "PTYProcess already spawned")

        // Готовим все C-строки В РОДИТЕЛЕ (после forkpty в ребёнке нельзя malloc).
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        let cwdC = cwd.map { strdup($0) }
        defer {
            for case let p? in cargs { free(p) }
            if let cwdC { free(cwdC) }
        }

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0
        let childPid = forkpty(&master, nil, nil, &ws)

        if childPid < 0 {
            throw PTYError.spawnFailed(errno)
        }

        if childPid == 0 {
            // CHILD: только async-signal-safe вызовы.
            if let cwdC { _ = chdir(cwdC) }
            execvp(cargs[0]!, &cargs)   // возвращается только при ошибке
            _exit(127)
        }

        // PARENT
        pid = childPid
        masterFD = master
        startReadLoop()
    }

    public func write(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = Darwin.write(self.masterFD, base, raw.count)
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &ws)
        }
    }

    public func kill() {
        queue.async { [weak self] in
            guard let self, self.pid > 0, !self.reaped else { return }
            _ = Darwin.kill(self.pid, SIGTERM)
        }
    }

    public func backfill(since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool) {
        queue.sync { buffer.since(seq) }
    }

    // MARK: - private

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        src.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD)
            self.masterFD = -1
        }
        readSource = src
        src.resume()
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(masterFD, base, raw.count)
        }
        if n > 0 {
            let chunk = Array(buf[0..<n])
            let range = buffer.append(chunk)
            onOutput?(chunk, range.from)
        } else {
            reap()   // EOF (n==0) или EIO после выхода ребёнка (n<0)
        }
    }

    private func reap() {
        guard !reaped else { return }
        reaped = true
        readSource?.cancel()
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff          // нормальный выход
        } else {
            code = 128 + (status & 0x7f)         // убит сигналом
        }
        onExit?(code)
    }
}
```

- [ ] **Step 4: Запустить тесты — зелёные**

Run: `swift test --filter PTYProcessTests`
Expected: PASS (6 тестов). Если `testResizeUpdatesWinsize` редко флейкует из-за гонки готовности shell — перезапустить; resize и write идут на одной serial-очереди, поэтому resize применяется раньше `stty size`.

- [ ] **Step 5: Commit** (пользователь)

```bash
git add Sources/CoveydCore/PTYProcess.swift Tests/CoveydCoreTests/PTYProcessTests.swift
git commit -m "feat(coveydcore): forkpty-backed PTYProcess (spawn/io/resize/kill)"
```

---

### Task 4: SessionRegistry (реестр сессий)

**Files:**
- Create: `Sources/CoveydCore/SessionRegistry.swift`
- Test: `Tests/CoveydCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `PTYProcess` (Task 3), `Session` (Task 1).
- Produces:
  - `public final class SessionRegistry`
    - `public init(clock: @escaping () -> Int64 = { Int64(time(nil)) })`
    - `public var onExit: ((String, Int32) -> Void)?` — (имя, код)
    - `public func create(dir: String, agent: String, argv: [String], name: String? = nil) throws -> Session`
    - `public func kill(name: String)`
    - `public func list() -> [Session]`
    - `public func get(name: String) -> Session?`
    - `public func attachOutput(name: String, _ handler: @escaping ([UInt8], Int) -> Void)`
    - `public func write(name: String, bytes: [UInt8])`
    - `public func resize(name: String, cols: UInt16, rows: UInt16)`
  - `public enum RegistryError: Error, Equatable { case duplicateName(String); case notFound(String) }`
  - Поведение: имя по умолчанию — `"s-<счётчик>"`; дубль имени → `RegistryError.duplicateName`;
    выход процесса сам удаляет запись и дёргает `onExit`.

- [ ] **Step 1: Написать падающие тесты** в `Tests/CoveydCoreTests/SessionRegistryTests.swift`

```swift
import XCTest
@testable import CoveydCore
import CoveyKit

final class SessionRegistryTests: XCTestCase {
    func testCreateAssignsNameAndClock() throws {
        let reg = SessionRegistry(clock: { 1234 })
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        XCTAssertFalse(s.name.isEmpty)
        XCTAssertEqual(s.created, 1234)
        XCTAssertEqual(reg.list().map(\.name), [s.name])
        reg.kill(name: s.name)
    }

    func testDuplicateNameThrows() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "dup")
        XCTAssertThrowsError(
            try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "dup")
        ) { error in
            XCTAssertEqual(error as? RegistryError, .duplicateName("dup"))
        }
        reg.kill(name: "dup")
    }

    func testKillRemovesFromList() throws {
        let reg = SessionRegistry()
        let exitExp = expectation(description: "exit")
        reg.onExit = { _, _ in exitExp.fulfill() }
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        reg.kill(name: s.name)
        wait(for: [exitExp], timeout: 5)
        XCTAssertTrue(reg.list().isEmpty)
    }

    func testTwoSessionsIndependentOutput() throws {
        let reg = SessionRegistry()
        let e1 = expectation(description: "o1"); e1.assertForOverFulfill = false
        let e2 = expectation(description: "o2"); e2.assertForOverFulfill = false
        let s1 = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        let s2 = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        var b1 = [UInt8]()
        var b2 = [UInt8]()
        reg.attachOutput(name: s1.name) { bytes, _ in
            b1 += bytes
            if String(decoding: b1, as: UTF8.self).contains("one") { e1.fulfill() }
        }
        reg.attachOutput(name: s2.name) { bytes, _ in
            b2 += bytes
            if String(decoding: b2, as: UTF8.self).contains("two") { e2.fulfill() }
        }
        reg.write(name: s1.name, bytes: Array("one\n".utf8))
        reg.write(name: s2.name, bytes: Array("two\n".utf8))
        wait(for: [e1, e2], timeout: 5)
        XCTAssertFalse(String(decoding: b1, as: UTF8.self).contains("two"))
        reg.kill(name: s1.name)
        reg.kill(name: s2.name)
    }
}
```

- [ ] **Step 2: Запустить тесты — убедиться, что падают**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — `cannot find 'SessionRegistry' in scope`.

- [ ] **Step 3: Реализовать `Sources/CoveydCore/SessionRegistry.swift`**

```swift
import Darwin
import CoveyKit

public enum RegistryError: Error, Equatable {
    case duplicateName(String)
    case notFound(String)
}

/// In-memory реестр живых сессий: имя -> (Session, PTYProcess).
/// Выход процесса автоматически удаляет запись и уведомляет через `onExit`.
public final class SessionRegistry {
    public var onExit: ((String, Int32) -> Void)?

    private var entries: [String: (session: Session, process: PTYProcess)] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0

    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) }) {
        self.clock = clock
    }

    public func create(
        dir: String, agent: String, argv: [String], name: String? = nil
    ) throws -> Session {
        lock.lock()
        counter += 1
        let id = name ?? "s-\(counter)"
        if entries[id] != nil {
            lock.unlock()
            throw RegistryError.duplicateName(id)
        }
        let session = Session(
            name: id, dir: dir, cwd: dir, agent: agent,
            created: clock(), git: nil, worktreeRepo: nil
        )
        let proc = PTYProcess()
        proc.onExit = { [weak self] code in self?.handleExit(id, code) }
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: 80, rows: 24)
        } catch {
            lock.unlock()
            throw error
        }
        entries[id] = (session, proc)
        lock.unlock()
        return session
    }

    public func kill(name: String) {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.kill()
    }

    public func list() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.session)
    }

    public func get(name: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]?.session
    }

    public func attachOutput(name: String, _ handler: @escaping ([UInt8], Int) -> Void) {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.onOutput = handler
    }

    public func write(name: String, bytes: [UInt8]) {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.write(bytes)
    }

    public func resize(name: String, cols: UInt16, rows: UInt16) {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.resize(cols: cols, rows: rows)
    }

    private func handleExit(_ id: String, _ code: Int32) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
        onExit?(id, code)
    }
}
```

- [ ] **Step 4: Запустить тесты — зелёные**

Run: `swift test --filter SessionRegistryTests`
Expected: PASS (4 теста).

- [ ] **Step 5: Прогнать весь набор (DoD среза)**

Run: `swift build && swift test`
Expected: build OK; все тесты зелёные (Models 2 + Scrollback 5 + PTYProcess 6 + Registry 4).

- [ ] **Step 6: Commit** (пользователь)

```bash
git add Sources/CoveydCore/SessionRegistry.swift Tests/CoveydCoreTests/SessionRegistryTests.swift
git commit -m "feat(coveydcore): in-memory SessionRegistry over PTYProcess"
```

---

## Definition of Done (срез 1)

1. `swift build` и `swift test` зелёные.
2. Наборы из всех задач проходят (Models, ScrollbackBuffer, PTYProcess, SessionRegistry).
3. Нет утечек блокирующих потоков (kill гасит read-source и закрывает fd через cancel-handler).
4. Ядро байт-прозрачно; модели `Session`/`GitInfo`/`Status` — Codable + round-trip тест.

## Следующий срез (не в этом плане)

IPC-сервер (Unix-сокет `~/.covey/coveyd.sock`, NDJSON request/response + события),
оборачивающий `SessionRegistry`; реальная точка входа в `main.swift`; порт status inference.
