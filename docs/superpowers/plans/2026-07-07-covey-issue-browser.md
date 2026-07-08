# Слайс 28 — браузер issues (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Таб Issue инспектора получает браузер GitHub issues: список с кешем и фаззи-поиском, детали, редактор (title/body/labels), close с причиной, delete с подтверждением, сессия из issue через NewSessionSheet.

**Architecture:** Отдельный модуль: чистые модели/парсеры/args-билдеры в `IssueModels.swift` + расширенный `IssueService` (общий раннер `runGh`), `@Observable IssueBrowserModel` с per-root stale-while-revalidate кешем и инжектируемыми gh-замыканиями (тестируется без сети), новые вью `IssueBrowserPane`/`IssueDetailView`/`IssueEditView`. Композер (`IssuePane`) не меняется, кроме выноса `statusCard` в общий файл и хука «esc → назад в список».

**Tech Stack:** Swift 6 / SwiftUI (macOS), gh CLI через `/usr/bin/env` (без шелла), XCTest.

**Spec:** `/covey/docs/superpowers/specs/2026-07-07-covey-issue-browser-design.md`

## Global Constraints

- Весь код, комментарии, идентификаторы — на английском (docs/ — русский).
- **Git-коммиты делает пользователь.** Шаг «Commit» = остановиться и предложить пользователю сообщение коммита. Никаких git-write команд от агента.
- TDD: скелет типа → тест → реализация. Тесты — XCTest, запуск `swift test --filter <TestClass>`.
- Пути в тексте — от корня репо (`/covey/...`), реальные файлы — `Sources/covey/...`.
- Имя сессии не может содержать `:` и `.` (`validateCreate` в `/covey/Sources/CoveyKit/CreateLogic.swift:99`).
- gh-вызовы: аргументы массивом прямо в процесс, ничего через шелл.
- SwiftUI-фокус: только по tick-сигналу, не по `onAppear` (см. memory `focus-handover-quirks`).
- После правок верить `swift build` / `swift test`, не SourceKit-диагностике.

## Терминология

- **screen таба Issue** (`AppModel.issueScreen`): `.browser` (список/детали/редактор) или `.composer` (существующий IssuePane). Дом — `.browser`.
- **mode браузера** (`IssueBrowserModel.screen`): `.list` / `.detail(n)` / `.edit(n)`.

---

### Task 1: GhIssue/GhLabel + parseIssues/parseLabels

**Files:**
- Create: `Sources/covey/IssueModels.swift`
- Test: `Tests/CoveyAppTests/IssueModelsTests.swift`

**Interfaces:**
- Produces: `struct GhLabel: Decodable, Equatable { name, color: String }`;
  `struct GhIssue: Decodable, Equatable { number: Int, title, body, state: String, author: String, labels: [GhLabel], updatedAt: Date, url: String; var isOpen: Bool }`;
  `func parseIssues(_ data: Data) -> [GhIssue]?`; `func parseLabels(_ data: Data) -> [GhLabel]?`.

- [ ] **Step 1: Скелет типов** — создать `Sources/covey/IssueModels.swift`:

```swift
import Foundation

/// One GitHub label as `gh` emits it (extra JSON keys are ignored).
struct GhLabel: Decodable, Equatable {
    var name: String
    var color: String
}

/// One GitHub issue from `gh issue list --json ...`. `author` is flattened
/// to the login; a deleted account decodes as "".
struct GhIssue: Decodable, Equatable {
    var number: Int
    var title: String
    var body: String
    var state: String          // "OPEN" / "CLOSED"
    var author: String
    var labels: [GhLabel]
    var updatedAt: Date
    var url: String

    var isOpen: Bool { state == "OPEN" }
}

/// Issues from `gh issue list --json` stdout; nil when the JSON is broken.
func parseIssues(_ data: Data) -> [GhIssue]? { nil }

/// Labels from `gh label list --json name,color` stdout.
func parseLabels(_ data: Data) -> [GhLabel]? { nil }
```

- [ ] **Step 2: Тест** — создать `Tests/CoveyAppTests/IssueModelsTests.swift`:

```swift
import Foundation
import XCTest
@testable import covey

final class IssueModelsTests: XCTestCase {
    // Trimmed real-shape gh output: author is an object, labels carry
    // extra keys, dates are ISO8601.
    static let issuesJSON = Data("""
    [{"number":12,"title":"Fix scroll","body":"body **md**","state":"OPEN",
      "author":{"id":"U1","is_bot":false,"login":"kashi","name":"K"},
      "labels":[{"id":"L1","name":"bug","color":"d73a4a","description":""}],
      "updatedAt":"2026-07-07T10:00:00Z",
      "url":"https://github.com/o/r/issues/12"},
     {"number":9,"title":"Тема: тёмная","body":"","state":"CLOSED",
      "author":null,"labels":[],
      "updatedAt":"2026-07-01T00:00:00Z",
      "url":"https://github.com/o/r/issues/9"}]
    """.utf8)

    func testParseIssues() throws {
        let issues = try XCTUnwrap(parseIssues(Self.issuesJSON))
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues[0].number, 12)
        XCTAssertEqual(issues[0].author, "kashi")
        XCTAssertEqual(issues[0].labels, [GhLabel(name: "bug", color: "d73a4a")])
        XCTAssertTrue(issues[0].isOpen)
        XCTAssertEqual(issues[1].author, "")      // deleted account -> ""
        XCTAssertEqual(issues[1].title, "Тема: тёмная")
        XCTAssertFalse(issues[1].isOpen)
    }

    func testParseIssuesEmptyAndBroken() {
        XCTAssertEqual(parseIssues(Data("[]".utf8)), [])
        XCTAssertNil(parseIssues(Data("not json".utf8)))
    }

    func testParseLabels() throws {
        let json = Data(#"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":""}]"#.utf8)
        let labels = try XCTUnwrap(parseLabels(json))
        XCTAssertEqual(labels.map(\.name), ["bug", "ui"])
        XCTAssertNil(parseLabels(Data("{".utf8)))
    }
}
```

- [ ] **Step 3: Запустить — должен упасть.**
Run: `swift test --filter IssueModelsTests`
Expected: FAIL (`parseIssues` возвращает nil).

- [ ] **Step 4: Реализация** — в `IssueModels.swift` заменить заглушки и добавить кастомный декод автора:

```swift
extension GhIssue {
    private struct Author: Decodable { var login: String }
    private enum CodingKeys: String, CodingKey {
        case number, title, body, state, author, labels, updatedAt, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try c.decode(String.self, forKey: .state)
        author = (try? c.decode(Author.self, forKey: .author).login) ?? ""
        labels = try c.decodeIfPresent([GhLabel].self, forKey: .labels) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        url = try c.decode(String.self, forKey: .url)
    }
}

func parseIssues(_ data: Data) -> [GhIssue]? {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode([GhIssue].self, from: data)
}

func parseLabels(_ data: Data) -> [GhLabel]? {
    try? JSONDecoder().decode([GhLabel].self, from: data)
}
```

- [ ] **Step 5: Тесты зелёные.**
Run: `swift test --filter IssueModelsTests`
Expected: PASS.

- [ ] **Step 6: Commit** — предложить пользователю: `feat(covey): GhIssue/GhLabel models and gh JSON parsers`

---

### Task 2: sessionNameForIssue + labelDiff

**Files:**
- Modify: `Sources/covey/IssueModels.swift`
- Test: `Tests/CoveyAppTests/IssueModelsTests.swift`

**Interfaces:**
- Produces: `func sessionNameForIssue(number: Int, title: String) -> String` (без `:` и `.`, ≤60 символов);
  `func labelDiff(original: [String], edited: [String]) -> (add: [String], remove: [String])` (отсортированы).

- [ ] **Step 1: Скелет** — добавить в `IssueModels.swift`:

```swift
/// Session name for "session from issue": "#12 title". validateCreate
/// forbids ':' and '.', so both are stripped; whitespace collapses; the
/// result is cut to 60 characters.
func sessionNameForIssue(number: Int, title: String) -> String { "" }

/// gh flags for a label edit: what to --add-label / --remove-label,
/// sorted for stable args.
func labelDiff(original: [String], edited: [String]) -> (add: [String], remove: [String]) {
    ([], [])
}
```

- [ ] **Step 2: Тест** — добавить в `IssueModelsTests.swift`:

```swift
func testSessionNameForIssue() {
    XCTAssertEqual(sessionNameForIssue(number: 12, title: "Fix scroll"),
                   "#12 Fix scroll")
    // ':' and '.' are forbidden by validateCreate; whitespace collapses.
    XCTAssertEqual(sessionNameForIssue(number: 7, title: "bug: v1.2  broken"),
                   "#7 bug v1 2 broken")
    let long = sessionNameForIssue(number: 1, title: String(repeating: "x", count: 100))
    XCTAssertLessThanOrEqual(long.count, 60)
    XCTAssertTrue(long.hasPrefix("#1 x"))
    // Cutting must not leave a trailing space.
    XCTAssertEqual(long, long.trimmingCharacters(in: .whitespaces))
}

func testLabelDiff() {
    let d = labelDiff(original: ["bug", "ui"], edited: ["ui", "urgent", "app"])
    XCTAssertEqual(d.add, ["app", "urgent"])
    XCTAssertEqual(d.remove, ["bug"])
    let same = labelDiff(original: ["a"], edited: ["a"])
    XCTAssertTrue(same.add.isEmpty && same.remove.isEmpty)
}
```

- [ ] **Step 3: Запустить — FAIL.**
Run: `swift test --filter IssueModelsTests`

- [ ] **Step 4: Реализация:**

```swift
func sessionNameForIssue(number: Int, title: String) -> String {
    let cleaned = title
        .replacingOccurrences(of: ":", with: " ")
        .replacingOccurrences(of: ".", with: " ")
        .split(separator: " ").joined(separator: " ")
    let name = cleaned.isEmpty ? "#\(number)" : "#\(number) \(cleaned)"
    guard name.count > 60 else { return name }
    return String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
}

func labelDiff(original: [String], edited: [String]) -> (add: [String], remove: [String]) {
    let o = Set(original), e = Set(edited)
    return (add: e.subtracting(o).sorted(), remove: o.subtracting(e).sorted())
}
```

- [ ] **Step 5: PASS.** Run: `swift test --filter IssueModelsTests`

- [ ] **Step 6: Commit** — `feat(covey): session-from-issue name and label diff helpers`

---

### Task 3: IssueState/CloseReason + args-билдеры

**Files:**
- Modify: `Sources/covey/IssueModels.swift` (enums)
- Modify: `Sources/covey/IssueService.swift` (args-билдеры рядом с `issueCreateArgs`)
- Test: `Tests/CoveyAppTests/IssueServiceTests.swift`

**Interfaces:**
- Produces: `enum IssueState: String, CaseIterable { case open, closed, all; func next() -> IssueState }`;
  `enum CloseReason: String { case completed = "completed"; case notPlanned = "not planned" }`;
  `func issueListArgs(state: IssueState, limit: Int = 100) -> [String]`;
  `func issueEditArgs(number: Int, title: String?, body: String?, addLabels: [String], removeLabels: [String]) -> [String]`;
  `func issueCloseArgs(number: Int, reason: CloseReason) -> [String]`;
  `func issueReopenArgs(number: Int) -> [String]`;
  `func issueDeleteArgs(number: Int) -> [String]`;
  `func labelListArgs() -> [String]`.

- [ ] **Step 1: Скелет** — в `IssueModels.swift`:

```swift
/// gh's --state filter; `next()` is the `o` key cycle in the list.
enum IssueState: String, CaseIterable, Equatable {
    case open, closed, all
    func next() -> IssueState {
        let all = IssueState.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }
}

/// gh issue close --reason values.
enum CloseReason: String, Equatable {
    case completed = "completed"
    case notPlanned = "not planned"
}
```

В `IssueService.swift` (после `issueCreateArgs`) — заглушки, возвращающие `[]`:

```swift
/// JSON fields the browser needs; bodies come with the list so the
/// detail screen needs no second call.
let issueListFields = "number,title,body,state,author,labels,updatedAt,url"

/// gh invocations for the issue browser; pure so tests pin flag layout.
func issueListArgs(state: IssueState, limit: Int = 100) -> [String] { [] }
func issueEditArgs(number: Int, title: String?, body: String?,
                   addLabels: [String], removeLabels: [String]) -> [String] { [] }
func issueCloseArgs(number: Int, reason: CloseReason) -> [String] { [] }
func issueReopenArgs(number: Int) -> [String] { [] }
func issueDeleteArgs(number: Int) -> [String] { [] }
func labelListArgs() -> [String] { [] }
```

- [ ] **Step 2: Тест** — добавить в `IssueServiceTests.swift`:

```swift
func testIssueListArgs() {
    XCTAssertEqual(issueListArgs(state: .open),
                   ["gh", "issue", "list", "--json", issueListFields,
                    "--state", "open", "--limit", "100"])
    XCTAssertEqual(issueListArgs(state: .all, limit: 50).suffix(4),
                   ["--state", "all", "--limit", "50"])
}

func testIssueStateCycle() {
    XCTAssertEqual(IssueState.open.next(), .closed)
    XCTAssertEqual(IssueState.closed.next(), .all)
    XCTAssertEqual(IssueState.all.next(), .open)
}

func testIssueEditArgsOnlyChanged() {
    XCTAssertEqual(
        issueEditArgs(number: 12, title: "t", body: nil,
                      addLabels: ["a"], removeLabels: ["b", "c"]),
        ["gh", "issue", "edit", "12", "--title", "t",
         "--add-label", "a", "--remove-label", "b", "--remove-label", "c"])
    XCTAssertEqual(issueEditArgs(number: 3, title: nil, body: "b",
                                 addLabels: [], removeLabels: []),
                   ["gh", "issue", "edit", "3", "--body", "b"])
}

func testCloseReopenDeleteLabelArgs() {
    XCTAssertEqual(issueCloseArgs(number: 5, reason: .notPlanned),
                   ["gh", "issue", "close", "5", "--reason", "not planned"])
    XCTAssertEqual(issueCloseArgs(number: 5, reason: .completed),
                   ["gh", "issue", "close", "5", "--reason", "completed"])
    XCTAssertEqual(issueReopenArgs(number: 5), ["gh", "issue", "reopen", "5"])
    XCTAssertEqual(issueDeleteArgs(number: 5),
                   ["gh", "issue", "delete", "5", "--yes"])
    XCTAssertEqual(labelListArgs(),
                   ["gh", "label", "list", "--json", "name,color"])
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueServiceTests`

- [ ] **Step 4: Реализация:**

```swift
func issueListArgs(state: IssueState, limit: Int = 100) -> [String] {
    ["gh", "issue", "list", "--json", issueListFields,
     "--state", state.rawValue, "--limit", String(limit)]
}

func issueEditArgs(number: Int, title: String?, body: String?,
                   addLabels: [String], removeLabels: [String]) -> [String] {
    var args = ["gh", "issue", "edit", String(number)]
    if let title { args += ["--title", title] }
    if let body { args += ["--body", body] }
    for l in addLabels { args += ["--add-label", l] }
    for l in removeLabels { args += ["--remove-label", l] }
    return args
}

func issueCloseArgs(number: Int, reason: CloseReason) -> [String] {
    ["gh", "issue", "close", String(number), "--reason", reason.rawValue]
}

func issueReopenArgs(number: Int) -> [String] {
    ["gh", "issue", "reopen", String(number)]
}

func issueDeleteArgs(number: Int) -> [String] {
    ["gh", "issue", "delete", String(number), "--yes"]
}

func labelListArgs() -> [String] {
    ["gh", "label", "list", "--json", "name,color"]
}
```

- [ ] **Step 5: PASS.** Run: `swift test --filter IssueServiceTests`

- [ ] **Step 6: Commit** — `feat(covey): gh args builders for issue browser`

---

### Task 4: runGh + рефактор create + async-обёртки сервиса

**Files:**
- Modify: `Sources/covey/IssueService.swift`
- Test: `Tests/CoveyAppTests/IssueServiceTests.swift`

**Interfaces:**
- Produces: `struct GhRun { var status: Int32; var stdout: Data; var stderr: Data }`;
  `func runGh(args: [String], dir: String) async -> GhRun?` (nil = spawn failed);
  `enum GhOutcome<T: Equatable>: Equatable { case success(T); case failure(String) }`;
  `IssueService.list(dir:state:) async -> GhOutcome<[GhIssue]>`;
  `IssueService.labelList(dir:) async -> GhOutcome<[GhLabel]>`;
  `IssueService.mutate(args:dir:) async -> String?` (nil = success, иначе — готовое к показу сообщение);
  `let ghNotFoundMessage: String`.
- Consumes: `parseIssues`/`parseLabels` (Task 1), args-билдеры (Task 3).

- [ ] **Step 1: Тест на runGh** (процесс без сети — `/usr/bin/env` найдёт `sh`):

```swift
func testRunGhCapturesOutputAndStatus() async {
    let ok = await runGh(args: ["sh", "-c", "echo out; echo err >&2"],
                         dir: NSTemporaryDirectory())
    XCTAssertEqual(ok?.status, 0)
    XCTAssertEqual(String(decoding: ok?.stdout ?? Data(), as: UTF8.self), "out\n")
    XCTAssertEqual(String(decoding: ok?.stderr ?? Data(), as: UTF8.self), "err\n")

    let fail = await runGh(args: ["sh", "-c", "exit 3"], dir: NSTemporaryDirectory())
    XCTAssertEqual(fail?.status, 3)
}
```

- [ ] **Step 2: FAIL** (компиляция: `runGh` не существует). Run: `swift test --filter IssueServiceTests`

- [ ] **Step 3: Реализация** — в `IssueService.swift` добавить и пересадить `create`:

```swift
let ghNotFoundMessage =
    "gh CLI not found — install it (brew install gh), then `gh auth login`"

/// A finished gh process. nil from runGh = the spawn itself failed.
struct GhRun {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Spawns `/usr/bin/env <args>` in `dir` off the main thread and waits.
/// Arguments go straight to the process — nothing passes through a shell.
func runGh(args: [String], dir: String) async -> GhRun? {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GhRun(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }.value
}
```

`IssueService.create` переписать поверх runGh — поведение 1:1 (notFound при nil и при статусе 127, stderr как fail-сообщение, парс URL, `--web` без URL):

```swift
static func create(dir: String, title: String, body: String,
                   assignMe: Bool = false, web: Bool = false) async -> IssueOutcome {
    let args = issueCreateArgs(title: title, body: body, assignMe: assignMe, web: web)
    guard let run = await runGh(args: args, dir: dir), run.status != 127 else {
        return .failure(message: ghNotFoundMessage)
    }
    guard run.status == 0 else {
        let msg = String(decoding: run.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(message: msg.isEmpty ? "gh issue create failed" : msg)
    }
    if web { return .success(url: "") }
    guard let url = parseIssueURL(String(decoding: run.stdout, as: UTF8.self)) else {
        return .failure(message: "issue created, but gh printed no URL — check GitHub")
    }
    return .success(url: url)
}
```

Добавить обёртки браузера:

```swift
/// gh call result for the browser; failure carries a display-ready message.
enum GhOutcome<T: Equatable>: Equatable {
    case success(T)
    case failure(String)
}

extension IssueService {
    private static func failureMessage(_ run: GhRun?, fallback: String) -> String {
        guard let run else { return ghNotFoundMessage }
        if run.status == 127 { return ghNotFoundMessage }
        let msg = String(decoding: run.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? fallback : msg
    }

    static func list(dir: String, state: IssueState) async -> GhOutcome<[GhIssue]> {
        let run = await runGh(args: issueListArgs(state: state), dir: dir)
        guard let run, run.status == 0 else {
            return .failure(failureMessage(run, fallback: "gh issue list failed"))
        }
        guard let issues = parseIssues(run.stdout) else {
            return .failure("gh returned unreadable issue JSON")
        }
        return .success(issues)
    }

    static func labelList(dir: String) async -> GhOutcome<[GhLabel]> {
        let run = await runGh(args: labelListArgs(), dir: dir)
        guard let run, run.status == 0 else {
            return .failure(failureMessage(run, fallback: "gh label list failed"))
        }
        guard let labels = parseLabels(run.stdout) else {
            return .failure("gh returned unreadable label JSON")
        }
        return .success(labels)
    }

    /// Edit/close/reopen/delete: nil = success, otherwise a display message.
    static func mutate(args: [String], dir: String) async -> String? {
        let run = await runGh(args: args, dir: dir)
        guard let run, run.status == 0 else {
            return failureMessage(run, fallback: "gh command failed")
        }
        return nil
    }
}
```

- [ ] **Step 4: Все тесты зелёные** (включая старые create-тесты).
Run: `swift test --filter IssueServiceTests && swift build`
Expected: PASS, сборка чистая.

- [ ] **Step 5: Commit** — `refactor(covey): shared runGh runner + async gh wrappers for browser`

---

### Task 5: кеш-политика (чистая функция)

**Files:**
- Create: `Sources/covey/IssueBrowserModel.swift`
- Test: `Tests/CoveyAppTests/IssueBrowserModelTests.swift`

**Interfaces:**
- Produces: `enum CachePlan: Equatable { case useCached, revalidate, fetch }`;
  `func cachePlan(fetchedAt: Date?, ttl: TimeInterval, now: Date) -> CachePlan`;
  `func staleNoteText(fetchedAt: Date, now: Date) -> String` («updated Nm ago — refresh failed»);
  `let issueCacheTTL: TimeInterval` (= 120).

- [ ] **Step 1: Скелет** — создать `Sources/covey/IssueBrowserModel.swift`:

```swift
import Foundation

/// Spec: stale-while-revalidate with a 120 s freshness window.
let issueCacheTTL: TimeInterval = 120

/// What to do on opening a list given the cache entry's age.
enum CachePlan: Equatable {
    case useCached      // fresh: show, no network
    case revalidate     // stale: show now, refetch in background
    case fetch          // no cache: full-screen loading
}

func cachePlan(fetchedAt: Date?, ttl: TimeInterval, now: Date) -> CachePlan { .fetch }

/// The banner when a background refresh failed and cached data stays up.
func staleNoteText(fetchedAt: Date, now: Date) -> String { "" }
```

- [ ] **Step 2: Тест** — создать `Tests/CoveyAppTests/IssueBrowserModelTests.swift`:

```swift
import Foundation
import XCTest
@testable import covey

final class IssueBrowserModelTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCachePlan() {
        XCTAssertEqual(cachePlan(fetchedAt: nil, ttl: 120, now: t0), .fetch)
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-60),
                                 ttl: 120, now: t0), .useCached)
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-120),
                                 ttl: 120, now: t0), .useCached)  // boundary = fresh
        XCTAssertEqual(cachePlan(fetchedAt: t0.addingTimeInterval(-121),
                                 ttl: 120, now: t0), .revalidate)
    }

    func testStaleNoteText() {
        XCTAssertEqual(staleNoteText(fetchedAt: t0.addingTimeInterval(-300), now: t0),
                       "updated 5m ago — refresh failed")
        XCTAssertEqual(staleNoteText(fetchedAt: t0.addingTimeInterval(-30), now: t0),
                       "updated 0m ago — refresh failed")
    }
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueBrowserModelTests`

- [ ] **Step 4: Реализация:**

```swift
func cachePlan(fetchedAt: Date?, ttl: TimeInterval, now: Date) -> CachePlan {
    guard let fetchedAt else { return .fetch }
    return now.timeIntervalSince(fetchedAt) <= ttl ? .useCached : .revalidate
}

func staleNoteText(fetchedAt: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(fetchedAt) / 60)
    return "updated \(minutes)m ago — refresh failed"
}
```

- [ ] **Step 5: PASS.** Run: `swift test --filter IssueBrowserModelTests`

- [ ] **Step 6: Commit** — `feat(covey): issue cache policy (stale-while-revalidate)`

---

### Task 6: IssueBrowserModel — открытие, кеш, выделение, фильтры

**Files:**
- Modify: `Sources/covey/IssueBrowserModel.swift`
- Test: `Tests/CoveyAppTests/IssueBrowserModelTests.swift`

**Interfaces:**
- Consumes: `GhOutcome`, `IssueState`, `GhIssue`, `cachePlan`, `staleNoteText`, `fuzzyMatch` (есть в `/covey/Sources/covey/Fuzzy.swift`).
- Produces (главное API модели; вью и AppModel зовут именно это):

```swift
@MainActor @Observable final class IssueBrowserModel {
    enum Screen: Equatable { case list, detail(Int), edit(Int) }
    enum Stage: Equatable { case idle, loading, ready, failed(String) }

    private(set) var issues: [GhIssue]
    private(set) var stage: Stage
    var screen: Screen
    private(set) var stateFilter: IssueState
    var query: String
    private(set) var selectedNumber: Int?
    private(set) var revalidating: Bool
    private(set) var staleNote: String?
    private(set) var root: String?
    private(set) var dir: String?

    var fetchIssues: (String, IssueState) async -> GhOutcome<[GhIssue]>
    var now: () -> Date

    init(fetchIssues: ..., now: ... = Date.init)   // см. Step 1
    func open(root: String, dir: String) async
    func refresh(force: Bool) async
    func cycleFilter() async
    func invalidate(root: String)
    func visible() -> [GhIssue]
    func selectedIssue() -> GhIssue?
    func moveSelection(_ delta: Int)
}
```

- [ ] **Step 1: Скелет** — дополнить `IssueBrowserModel.swift`:

```swift
import Observation

/// State machine of the inspector's issue browser. gh access is injected
/// so the whole flow tests without a network; the UI owns no state.
@MainActor @Observable
final class IssueBrowserModel {
    enum Screen: Equatable { case list, detail(Int), edit(Int) }
    enum Stage: Equatable { case idle, loading, ready, failed(String) }

    struct CacheEntry {
        var issues: [GhIssue]
        var fetchedAt: Date
    }

    private(set) var issues: [GhIssue] = []
    private(set) var stage: Stage = .idle
    var screen: Screen = .list
    private(set) var stateFilter: IssueState = .open
    var query = ""
    private(set) var selectedNumber: Int?
    private(set) var revalidating = false
    private(set) var staleNote: String?
    private(set) var root: String?
    private(set) var dir: String?

    private var cache: [String: CacheEntry] = [:]

    var fetchIssues: (String, IssueState) async -> GhOutcome<[GhIssue]>
    var now: () -> Date

    init(fetchIssues: @escaping (String, IssueState) async -> GhOutcome<[GhIssue]>,
         now: @escaping () -> Date = Date.init) {
        self.fetchIssues = fetchIssues
        self.now = now
    }

    private func cacheKey(_ root: String, _ state: IssueState) -> String {
        "\(root)|\(state.rawValue)"
    }

    func open(root: String, dir: String) async {}
    func refresh(force: Bool) async {}
    func cycleFilter() async {}
    func invalidate(root: String) {}
    func visible() -> [GhIssue] { [] }
    func selectedIssue() -> GhIssue? { nil }
    func moveSelection(_ delta: Int) {}
}
```

- [ ] **Step 2: Тесты** — добавить в `IssueBrowserModelTests.swift` (фейковый fetcher со счётчиком):

```swift
@MainActor
final class IssueBrowserModelFlowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func issue(_ n: Int, _ title: String, open: Bool = true) -> GhIssue {
        GhIssue(number: n, title: title, body: "b", state: open ? "OPEN" : "CLOSED",
                author: "a", labels: [], updatedAt: Date(timeIntervalSince1970: 0),
                url: "https://github.com/o/r/issues/\(n)")
    }

    /// Model with a scripted fetcher; `calls` counts network hits.
    func makeBrowser(result: @escaping () -> GhOutcome<[GhIssue]>,
                     calls: @escaping () -> Void = {},
                     now: Date? = nil) -> IssueBrowserModel {
        let clock = now ?? t0
        return IssueBrowserModel(fetchIssues: { _, _ in
            calls()
            return result()
        }, now: { clock })
    }

    func testOpenFetchesAndCaches() async {
        var count = 0
        let m = makeBrowser(result: { .success([self.issue(1, "one")]) },
                            calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .ready)
        XCTAssertEqual(m.issues.map(\.number), [1])
        XCTAssertEqual(m.selectedNumber, 1)
        XCTAssertEqual(count, 1)
        // Re-open within TTL: cache serves, no second call.
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 1)
    }

    func testOpenFailureWithoutCacheIsFullScreenFailed() async {
        let m = makeBrowser(result: { .failure("boom") })
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .failed("boom"))
    }

    func testStaleServesCacheAndRevalidates() async {
        var count = 0
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "one")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in count += 1; return result },
                                  now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        // Fast-forward past the TTL and refetch with fresh data.
        m.now = { self.t0.addingTimeInterval(issueCacheTTL + 1) }
        result = .success([issue(1, "one"), issue(2, "two")])
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 2)                       // revalidated
        XCTAssertEqual(m.issues.count, 2)              // replaced by fresh data
        XCTAssertNil(m.staleNote)
    }

    func testStaleRefetchFailureKeepsCacheWithNote() async {
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "one")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in result }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        m.now = { self.t0.addingTimeInterval(400) }
        result = .failure("offline")
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(m.stage, .ready)                // cache still on screen
        XCTAssertEqual(m.issues.map(\.number), [1])
        XCTAssertEqual(m.staleNote, "updated 6m ago — refresh failed")
    }

    func testSelectionSurvivesListReplacementByNumber() async {
        var result: GhOutcome<[GhIssue]> = .success([issue(1, "a"), issue(2, "b")])
        let m = IssueBrowserModel(fetchIssues: { _, _ in result }, now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        m.moveSelection(1)
        XCTAssertEqual(m.selectedNumber, 2)
        result = .success([issue(2, "b"), issue(3, "c")])   // #1 vanished
        await m.refresh(force: true)
        XCTAssertEqual(m.selectedNumber, 2)                 // kept by number
        result = .success([issue(9, "z")])                  // #2 vanished too
        await m.refresh(force: true)
        XCTAssertEqual(m.selectedNumber, 9)                 // falls to first
    }

    func testCycleFilterCachesPerFilter() async {
        var count = 0
        let m = makeBrowser(result: { .success([]) }, calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")      // open filter, fetch 1
        await m.cycleFilter()                    // closed, fetch 2
        XCTAssertEqual(m.stateFilter, .closed)
        await m.cycleFilter()                    // all, fetch 3
        await m.cycleFilter()                    // back to open: cached, no fetch
        XCTAssertEqual(m.stateFilter, .open)
        XCTAssertEqual(count, 3)
    }

    func testInvalidateForcesNextFetch() async {
        var count = 0
        let m = makeBrowser(result: { .success([self.issue(1, "a")]) },
                            calls: { count += 1 })
        await m.open(root: "/r", dir: "/r")
        m.invalidate(root: "/r")
        await m.open(root: "/r", dir: "/r")
        XCTAssertEqual(count, 2)
    }

    func testVisibleAppliesFuzzyQuery() async {
        let m = makeBrowser(result: {
            .success([self.issue(1, "Fix scroll bug"), self.issue(2, "Add themes")])
        })
        await m.open(root: "/r", dir: "/r")
        m.query = "them"
        XCTAssertEqual(m.visible().map(\.number), [2])
        m.query = "#1"
        XCTAssertEqual(m.visible().map(\.number), [1])   // matches "#num title"
        m.query = ""
        XCTAssertEqual(m.visible().count, 2)
    }

    func testMoveSelectionWalksVisibleAndClamps() async {
        let m = makeBrowser(result: {
            .success([self.issue(1, "a"), self.issue(2, "b"), self.issue(3, "c")])
        })
        await m.open(root: "/r", dir: "/r")
        m.moveSelection(1); m.moveSelection(1)
        XCTAssertEqual(m.selectedNumber, 3)
        m.moveSelection(1)                       // clamps at the end
        XCTAssertEqual(m.selectedNumber, 3)
        m.moveSelection(-5)                      // clamps at the start
        XCTAssertEqual(m.selectedNumber, 1)
    }
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueBrowserModelFlowTests`

- [ ] **Step 4: Реализация** — заполнить методы:

```swift
func open(root: String, dir: String) async {
    self.root = root
    self.dir = dir
    let key = cacheKey(root, stateFilter)
    switch cachePlan(fetchedAt: cache[key]?.fetchedAt, ttl: issueCacheTTL, now: now()) {
    case .useCached:
        issues = cache[key]!.issues
        stage = .ready
        ensureSelection()
    case .revalidate:
        issues = cache[key]!.issues
        stage = .ready
        ensureSelection()
        await revalidate(key: key)
    case .fetch:
        stage = .loading
        await fetchInto(key: key)
    }
}

func refresh(force: Bool) async {
    guard let root, dir != nil else { return }
    let key = cacheKey(root, stateFilter)
    if force { cache[key] = nil }
    if issues.isEmpty { stage = .loading }
    await fetchInto(key: key)
}

func cycleFilter() async {
    stateFilter = stateFilter.next()
    guard let root, let dir else { return }
    await open(root: root, dir: dir)
}

func invalidate(root: String) {
    for state in IssueState.allCases {
        cache[cacheKey(root, state)] = nil
    }
}

func visible() -> [GhIssue] {
    guard !query.isEmpty else { return issues }
    return issues.filter { fuzzyMatch(query, "#\($0.number) \($0.title)") }
}

func selectedIssue() -> GhIssue? {
    issues.first { $0.number == selectedNumber }
}

func moveSelection(_ delta: Int) {
    let rows = visible()
    guard !rows.isEmpty else { return }
    let cur = rows.firstIndex { $0.number == selectedNumber } ?? 0
    let next = min(max(cur + delta, 0), rows.count - 1)
    selectedNumber = rows[next].number
}

/// Keeps the selection on the same issue number across list replacement;
/// falls back to the first visible row.
private func ensureSelection() {
    let rows = visible()
    if let selectedNumber, rows.contains(where: { $0.number == selectedNumber }) { return }
    selectedNumber = rows.first?.number
}

private func fetchInto(key: String) async {
    guard let dir else { return }
    switch await fetchIssues(dir, stateFilter) {
    case .success(let fresh):
        cache[key] = CacheEntry(issues: fresh, fetchedAt: now())
        issues = fresh
        stage = .ready
        staleNote = nil
        ensureSelection()
    case .failure(let msg):
        if issues.isEmpty { stage = .failed(msg) }
        else if let entry = cache[key] {
            staleNote = staleNoteText(fetchedAt: entry.fetchedAt, now: now())
        } else {
            staleNote = "refresh failed: \(msg)"
        }
    }
}

private func revalidate(key: String) async {
    revalidating = true
    await fetchInto(key: key)
    revalidating = false
}
```

- [ ] **Step 5: PASS + полный прогон.**
Run: `swift test --filter IssueBrowserModelFlowTests && swift test`
Expected: PASS, ничего не сломано.

- [ ] **Step 6: Commit** — `feat(covey): IssueBrowserModel — cache, selection, filters`

---

### Task 7: IssueBrowserModel — лейблы, save, close/reopen/delete

**Files:**
- Modify: `Sources/covey/IssueBrowserModel.swift`
- Test: `Tests/CoveyAppTests/IssueBrowserModelTests.swift`

**Interfaces:**
- Produces (добавка к модели):

```swift
enum Prompt: Equatable { case closeReason(Int), deleteConfirm(Int) }
private(set) var prompt: Prompt?
private(set) var labels: [GhLabel]?
private(set) var labelsLoading: Bool
private(set) var actionBusy: Bool
var fetchLabels: (String) async -> GhOutcome<[GhLabel]>
var runMutation: ([String], String) async -> String?   // (args, dir) -> error?
var toast: (String) -> Void

func loadLabelsIfNeeded() async
func saveEdit(number: Int, title: String?, body: String?,
              addLabels: [String], removeLabels: [String]) async -> Bool
func beginClose()      // prompt = .closeReason(selected) on an open issue
func closeSelected(reason: CloseReason) async
func reopenSelected() async
func beginDelete()     // prompt = .deleteConfirm(selected)
func deleteConfirmed() async
func cancelPrompt()
```

- Consumes: `issueEditArgs`/`issueCloseArgs`/`issueReopenArgs`/`issueDeleteArgs` (Task 3), `invalidate`/`refresh` (Task 6).

- [ ] **Step 1: Скелет** — добавить поля в класс (init получает новые параметры с дефолтами, чтобы Task 6 тесты не менялись):

```swift
enum Prompt: Equatable { case closeReason(Int), deleteConfirm(Int) }

private(set) var prompt: Prompt?
private(set) var labels: [GhLabel]?
private(set) var labelsLoading = false
private(set) var actionBusy = false

var fetchLabels: (String) async -> GhOutcome<[GhLabel]>
var runMutation: ([String], String) async -> String?
var toast: (String) -> Void
```

Обновлённый init (дефолты — заглушки, живую сборку даёт `live` ниже в Task 8):

```swift
init(fetchIssues: @escaping (String, IssueState) async -> GhOutcome<[GhIssue]>,
     fetchLabels: @escaping (String) async -> GhOutcome<[GhLabel]> = { _ in .success([]) },
     runMutation: @escaping ([String], String) async -> String? = { _, _ in nil },
     toast: @escaping (String) -> Void = { _ in },
     now: @escaping () -> Date = Date.init) {
    self.fetchIssues = fetchIssues
    self.fetchLabels = fetchLabels
    self.runMutation = runMutation
    self.toast = toast
    self.now = now
}
```

Методы-заглушки: `loadLabelsIfNeeded() async {}`, `saveEdit(...) async -> Bool { false }`, `beginClose() {}`, `closeSelected(reason:) async {}`, `reopenSelected() async {}`, `beginDelete() {}`, `deleteConfirmed() async {}`, `cancelPrompt() {}`.

- [ ] **Step 2: Тесты** — добавить класс в `IssueBrowserModelTests.swift`:

```swift
@MainActor
final class IssueBrowserModelActionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func issue(_ n: Int, open: Bool = true) -> GhIssue {
        GhIssue(number: n, title: "t\(n)", body: "b", state: open ? "OPEN" : "CLOSED",
                author: "a", labels: [], updatedAt: Date(timeIntervalSince1970: 0),
                url: "https://github.com/o/r/issues/\(n)")
    }

    struct Recorder {
        var mutations: [[String]] = []
        var toasts: [String] = []
        var fetchCount = 0
    }

    /// Browser over one scripted issue list; mutations recorded, not run.
    func makeBrowser(_ issues: [GhIssue],
                     mutationError: String? = nil) async
        -> (IssueBrowserModel, () -> Recorder) {
        var recorder = Recorder()
        let m = IssueBrowserModel(
            fetchIssues: { _, _ in recorder.fetchCount += 1; return .success(issues) },
            fetchLabels: { _ in .success([GhLabel(name: "bug", color: "d73a4a")]) },
            runMutation: { args, _ in recorder.mutations.append(args); return mutationError },
            toast: { recorder.toasts.append($0) },
            now: { self.t0 })
        await m.open(root: "/r", dir: "/r")
        return (m, { recorder })
    }

    func testLabelsLoadOnce() async {
        let (m, _) = await makeBrowser([issue(1)])
        await m.loadLabelsIfNeeded()
        XCTAssertEqual(m.labels?.map(\.name), ["bug"])
        await m.loadLabelsIfNeeded()          // second call is a no-op
        XCTAssertEqual(m.labels?.count, 1)
    }

    func testCloseFlow() async {
        let (m, rec) = await makeBrowser([issue(1)])
        m.beginClose()
        XCTAssertEqual(m.prompt, .closeReason(1))
        await m.closeSelected(reason: .notPlanned)
        XCTAssertNil(m.prompt)
        XCTAssertEqual(rec().mutations,
                       [["gh", "issue", "close", "1", "--reason", "not planned"]])
        XCTAssertEqual(rec().toasts, ["issue #1 closed"])
        XCTAssertEqual(rec().fetchCount, 2)   // open + post-mutation refetch
    }

    func testBeginCloseOnClosedIssueReopensInstead() async {
        let (m, rec) = await makeBrowser([issue(2, open: false)])
        m.beginClose()
        XCTAssertNil(m.prompt)                // no reason prompt for reopen
        await m.reopenSelected()
        XCTAssertEqual(rec().mutations, [["gh", "issue", "reopen", "2"]])
        XCTAssertEqual(rec().toasts, ["issue #2 reopened"])
    }

    func testDeleteFlow() async {
        let (m, rec) = await makeBrowser([issue(3)])
        m.screen = .detail(3)
        m.beginDelete()
        XCTAssertEqual(m.prompt, .deleteConfirm(3))
        await m.deleteConfirmed()
        XCTAssertEqual(rec().mutations, [["gh", "issue", "delete", "3", "--yes"]])
        XCTAssertEqual(rec().toasts, ["issue #3 deleted"])
        XCTAssertEqual(m.screen, .list)       // deleted from detail -> back to list
    }

    func testMutationErrorToastsAndKeepsScreen() async {
        let (m, rec) = await makeBrowser([issue(1)], mutationError: "admin only")
        m.beginDelete()
        await m.deleteConfirmed()
        XCTAssertEqual(rec().toasts, ["admin only"])
        XCTAssertEqual(rec().fetchCount, 1)   // failed mutation: no refetch
        XCTAssertFalse(m.actionBusy)
    }

    func testSaveEdit() async {
        let (m, rec) = await makeBrowser([issue(1)])
        let ok = await m.saveEdit(number: 1, title: "new", body: nil,
                                  addLabels: ["bug"], removeLabels: [])
        XCTAssertTrue(ok)
        XCTAssertEqual(rec().mutations,
                       [["gh", "issue", "edit", "1", "--title", "new",
                         "--add-label", "bug"]])
        XCTAssertEqual(rec().toasts, ["issue #1 updated"])
    }

    func testSaveEditNoChangesSkipsGh() async {
        let (m, rec) = await makeBrowser([issue(1)])
        let ok = await m.saveEdit(number: 1, title: nil, body: nil,
                                  addLabels: [], removeLabels: [])
        XCTAssertTrue(ok)
        XCTAssertTrue(rec().mutations.isEmpty)
    }

    func testCancelPrompt() async {
        let (m, _) = await makeBrowser([issue(1)])
        m.beginDelete()
        m.cancelPrompt()
        XCTAssertNil(m.prompt)
    }
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueBrowserModelActionTests`

- [ ] **Step 4: Реализация:**

```swift
func loadLabelsIfNeeded() async {
    guard labels == nil, !labelsLoading, let dir else { return }
    labelsLoading = true
    if case .success(let fetched) = await fetchLabels(dir) { labels = fetched }
    labelsLoading = false
}

/// Runs one mutation; on success invalidates the root cache and refetches.
/// Returns true on success.
private func performMutation(_ args: [String], successToast: String) async -> Bool {
    guard let root, let dir, !actionBusy else { return false }
    actionBusy = true
    defer { actionBusy = false }
    if let error = await runMutation(args, dir) {
        toast(error)
        return false
    }
    toast(successToast)
    invalidate(root: root)
    await refresh(force: true)
    return true
}

func beginClose() {
    guard let issue = selectedIssue() else { return }
    guard issue.isOpen else { return }        // closed -> caller reopens
    prompt = .closeReason(issue.number)
}

func closeSelected(reason: CloseReason) async {
    guard case .closeReason(let n) = prompt else { return }
    prompt = nil
    _ = await performMutation(issueCloseArgs(number: n, reason: reason),
                              successToast: "issue #\(n) closed")
}

func reopenSelected() async {
    guard let issue = selectedIssue(), !issue.isOpen else { return }
    _ = await performMutation(issueReopenArgs(number: issue.number),
                              successToast: "issue #\(issue.number) reopened")
}

func beginDelete() {
    guard let issue = selectedIssue() else { return }
    prompt = .deleteConfirm(issue.number)
}

func deleteConfirmed() async {
    guard case .deleteConfirm(let n) = prompt else { return }
    prompt = nil
    let deleted = await performMutation(issueDeleteArgs(number: n),
                                        successToast: "issue #\(n) deleted")
    if deleted, case .detail(n) = screen { screen = .list }
}

func cancelPrompt() { prompt = nil }

func saveEdit(number: Int, title: String?, body: String?,
              addLabels: [String], removeLabels: [String]) async -> Bool {
    if title == nil, body == nil, addLabels.isEmpty, removeLabels.isEmpty {
        return true   // nothing changed — no gh call
    }
    let args = issueEditArgs(number: number, title: title, body: body,
                             addLabels: addLabels, removeLabels: removeLabels)
    return await performMutation(args, successToast: "issue #\(number) updated")
}
```

- [ ] **Step 5: PASS + полный прогон.** Run: `swift test`

- [ ] **Step 6: Commit** — `feat(covey): IssueBrowserModel actions — edit, close, reopen, delete`

---

### Task 8: KeyRouter `space g l` + AppModel-вязка + префилл имени

**Files:**
- Modify: `Sources/covey/KeyRouter.swift` (KeyAction + leader)
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/covey/Views/WhichKeyView.swift` (строка `l` в git-меню)
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`, `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Produces: `KeyAction.openIssueList`; в AppModel:
  `public enum IssueScreen: Equatable { case browser, composer }`;
  `public private(set) var issueScreen: IssueScreen` (default `.browser`);
  `public func setIssueScreen(_ s: IssueScreen)` (композеру нужен переход из вью);
  `public let issueBrowser: IssueBrowserModel`;
  `public private(set) var newSessionPrefillName: String?`;
  `public func newSessionFromIssue(number: Int, title: String)`;
  `clearNewSessionPrefill()` чистит **оба** префилла.
- Consumes: `IssueBrowserModel` (Task 6/7), `IssueService.list/labelList/mutate` (Task 4), `sessionNameForIssue` (Task 2).

- [ ] **Step 1: Тест роутинга** — в `KeyRouterTests.swift` (по образцу соседних leader-тестов; посмотреть файл и добавить):

```swift
func testGitLeaderRoutesIssueList() {
    let ctx = KeyRouter.Context(mode: .leader(.git), focus: .sessions,
                                vimMode: true, sheetOpen: false)
    XCTAssertEqual(KeyRouter.route(KeyInput(char: "l"), context: ctx),
                   .openIssueList)
}
```

- [ ] **Step 2: FAIL** (нет `.openIssueList`). Run: `swift test --filter KeyRouterTests`

- [ ] **Step 3: Реализация роутинга.**
В `KeyAction` добавить кейс `case openIssueList`. В `routeLeader` после `case (.git, "i")`:

```swift
case (.git, "l"): return .openIssueList
```

В `WhichKeyView` git-меню добавить строку (после `i`):

```swift
Row(key: "l", label: "list issues", implemented: true),
```

и в root-строке git обновить подпись: `"git — issue · list · promote · delete branch · cleanup · return"`.

- [ ] **Step 4: AppModel-вязка.**
Свойства (рядом с `issueFocusTick`, `AppModel.swift:77`):

```swift
/// Which screen the inspector's Issue tab shows; browser is home.
public enum IssueScreen: Equatable { case browser, composer }
public private(set) var issueScreen: IssueScreen = .browser
/// Session name to prefill in the New Session sheet (set by issue's `s`).
public private(set) var newSessionPrefillName: String?
/// The issue browser's state machine (gh access injected here).
public let issueBrowser: IssueBrowserModel
```

В `init` (до использования self в замыканиях — сначала создать, потом донастроить):

```swift
issueBrowser = IssueBrowserModel(
    fetchIssues: { dir, state in await IssueService.list(dir: dir, state: state) },
    fetchLabels: { dir in await IssueService.labelList(dir: dir) },
    runMutation: { args, dir in await IssueService.mutate(args: args, dir: dir) })
```

и после остальной инициализации:

```swift
issueBrowser.toast = { [weak self] msg in self?.showToast(msg) }
```

Методы:

```swift
public func setIssueScreen(_ s: IssueScreen) { issueScreen = s }

public func newSessionFromIssue(number: Int, title: String) {
    guard let root = sessionRootOfSelected() else { return }
    newSessionPrefillDir = root
    newSessionPrefillName = sessionNameForIssue(number: number, title: title)
    modal = .newSession
}
```

`clearNewSessionPrefill()` (строка 525) теперь чистит оба:

```swift
public func clearNewSessionPrefill() {
    newSessionPrefillDir = nil
    newSessionPrefillName = nil
}
```

В `apply(_:)` — новый кейс (рядом с `.createIssue`) и правка существующего:

```swift
case .openIssueList:
    inputMode = .normal
    guard let s = selectedSession() else { toast = "no session"; return }
    if s.git == nil { toast = "not a git repo"; return }
    if !showInspector { setShowInspector(true) }
    issueScreen = .browser
    issueBrowser.screen = .list
    setFocus(.inspector)
    selectInspectorTab(.issue)
    let root = sessionRoot(s)
    let dir = s.dir
    Task { await issueBrowser.open(root: root, dir: dir) }
```

В кейсе `.createIssue` (строка 683) добавить `issueScreen = .composer` перед `issueFocusTick += 1`.

- [ ] **Step 5: Тест вязки** — в `AppModelChromeTests.swift` (использует `makeModel` из AppTestSupport; посмотреть соседние тесты и повторить сетап):

```swift
@MainActor
func testOpenIssueListGuards() async throws {
    let daemon = try TestDaemon()
    defer { daemon.stop() }
    let (model, _) = try makeModel(daemon)
    model.apply(.openIssueList)
    XCTAssertEqual(model.toast, "no session")   // guard fires, nothing opens
    XCTAssertNotEqual(model.focus, .inspector)
}

@MainActor
func testNewSessionFromIssueWithoutSessionIsNoop() async throws {
    let daemon = try TestDaemon()
    defer { daemon.stop() }
    let (model, _) = try makeModel(daemon)
    model.newSessionFromIssue(number: 5, title: "t")
    XCTAssertNil(model.modal)
    XCTAssertNil(model.newSessionPrefillName)
}
```

- [ ] **Step 6: Всё зелёное.** Run: `swift test --filter KeyRouterTests && swift test --filter AppModelChromeTests && swift build`

- [ ] **Step 7: Commit** — `feat(covey): space g l opens issue list; session-from-issue prefill channel`

---

### Task 9: NewSessionSheet — префилл имени

**Files:**
- Modify: `Sources/covey/Views/NewSessionSheet.swift:91-99` (`onAppear`)

**Interfaces:**
- Consumes: `model.newSessionPrefillName` (Task 8).

- [ ] **Step 1: Правка `onAppear`** (перед `model.clearNewSessionPrefill()`):

```swift
if let prefillName = model.newSessionPrefillName {
    name = prefillName
}
```

- [ ] **Step 2: Сборка + прогон.** Run: `swift build && swift test`
Expected: чисто (view-код — без юнит-тестов, логика префилла покрыта Task 2/8).

- [ ] **Step 3: Commit** — `feat(covey): NewSessionSheet consumes issue name prefill`

---

### Task 10: statusCard — в общий файл

**Files:**
- Create: `Sources/covey/Views/StatusCard.swift`
- Modify: `Sources/covey/Views/IssuePane.swift:85-106` (удалить приватный `statusCard`, звать общий)

**Interfaces:**
- Produces: `func statusCard(tk: Tokens, icon: String? = nil, tint: Color, title: String, spinner: Bool = false, @ViewBuilder content: () -> some View) -> some View` — тот же вид, что нынешний приватный (surf2-фон, hairline-рамка в цвет исхода).

- [ ] **Step 1: Создать `Sources/covey/Views/StatusCard.swift`** — перенести тело из IssuePane, добавив параметр `tk`:

```swift
import SwiftUI

/// gh-outcome card in the pane idiom: surf2 fill, hairline border tinted
/// by the outcome, tiered text — same family as ayuField/AyuButton.
/// Shared by the issue composer and the issue browser.
func statusCard(tk: Tokens, icon: String? = nil, tint: Color, title: String,
                spinner: Bool = false,
                @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
            }
            Text(title)
                .font(.callout.weight(.semibold)).foregroundStyle(tk.t1)
        }
        content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tk.surf2, in: RoundedRectangle(cornerRadius: Tokens.r))
    .overlay(RoundedRectangle(cornerRadius: Tokens.r)
        .strokeBorder(tint.opacity(0.35)))
}
```

- [ ] **Step 2: IssuePane** — удалить приватный `statusCard` (строки 83–106) и заменить три вызова на `statusCard(tk: tk, ...)`: `.creating` → `statusCard(tk: tk, tint: tk.wait, ...)`, `.done` → `statusCard(tk: tk, icon: "checkmark", tint: tk.ok, ...)`, `.failed` → `statusCard(tk: tk, icon: "xmark", tint: tk.err, ...)`.

- [ ] **Step 3: Сборка + тесты.** Run: `swift build && swift test`

- [ ] **Step 4: Commit** — `refactor(covey): statusCard extracted for reuse by issue browser`

---

### Task 11: IssueBrowserPane — роутер + список

**Files:**
- Create: `Sources/covey/Views/IssueBrowserPane.swift`
- Modify: `Sources/covey/Views/InspectorView.swift:16,20` (IssuePane → IssueBrowserPane)
- Modify: `Sources/covey/Views/IssuePane.swift` (хук «esc → назад в браузер»)

**Interfaces:**
- Consumes: `model.issueScreen`/`setIssueScreen` (Task 8), `model.issueBrowser` (API Task 6/7), `model.issueFocusTick`, `statusCard` (Task 10), `KbdBadge`, `collapseHome`, `latinize`.
- Produces: `struct IssueBrowserPane: View { @Bindable var model: AppModel }` — роутер: `.composer` → `IssuePane`, `.browser` → список/детали/редактор; `IssueDetailView`/`IssueEditView` подключаются в Tasks 12–13 (тут — заглушки `Text`).

- [ ] **Step 1: Создать `IssueBrowserPane.swift`:**

```swift
import SwiftUI
import AppKit

/// Issue tab router: the browser (list/detail/edit) or the composer.
/// Keyboard-first: the list owns plain vim keys via .onKeyPress — the
/// ContentView monitor passes inspector plain keys through (see the
/// "inspector zone owns its plain keys" branch).
struct IssueBrowserPane: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var browser: IssueBrowserModel { model.issueBrowser }
    private var root: String? { model.sessionRootOfSelected() }

    var body: some View {
        Group {
            if root == nil {
                Text("select a session in a git repo")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.issueScreen == .composer {
                IssuePane(model: model)
                    .onExitCommand { backToBrowser() }
            } else {
                browserBody
            }
        }
        .onChange(of: model.issueFocusTick) { _, _ in
            guard model.issueScreen == .browser else { return }
            openList()
        }
    }

    private func backToBrowser() {
        model.setIssueScreen(.browser)
        openList()
    }

    private func openList() {
        if let root, let dir = model.sessions.first(where: { $0.name == model.selected })?.dir {
            Task { await browser.open(root: root, dir: dir) }
        }
        listFocused = true
    }

    @ViewBuilder
    private var browserBody: some View {
        switch browser.screen {
        case .list: listScreen
        case .detail(let n): Text("detail #\(n)")   // Task 12
        case .edit(let n): Text("edit #\(n)")       // Task 13
        }
    }

    // MARK: - list

    private var listScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if searchVisible { searchField }
            listBody
            if let prompt = browser.prompt { promptCard(prompt) }   // Task 14
            Spacer(minLength: 0)
            footerHints
        }
        .padding(8)
    }

    @State private var searchVisible = false

    private var header: some View {
        HStack(spacing: 6) {
            Text("in: \(collapseHome(root ?? ""))")
                .font(.caption.monospaced()).foregroundStyle(tk.t3).lineLimit(1)
            Spacer()
            if browser.revalidating {
                ProgressView().controlSize(.mini)
            }
            Text(browser.stateFilter.rawValue)
                .font(.caption2.monospaced()).foregroundStyle(tk.accent)
        }
    }

    private var searchField: some View {
        TextField("fuzzy filter", text: Binding(
            get: { browser.query }, set: { browser.query = $0 }))
            .focused($searchFocused)
            .ayuField(tk, focused: searchFocused)
            .onSubmit { searchFocused = false; listFocused = true }
            .onExitCommand {
                browser.query = ""
                searchVisible = false
                searchFocused = false
                listFocused = true
            }
    }

    @ViewBuilder
    private var listBody: some View {
        switch browser.stage {
        case .idle, .loading:
            statusCard(tk: tk, tint: tk.wait, title: "loading issues…", spinner: true) {
                EmptyView()
            }
        case .failed(let msg):
            statusCard(tk: tk, icon: "xmark", tint: tk.err, title: "gh failed") {
                Text(msg).font(.caption.monospaced()).foregroundStyle(tk.t2)
                    .textSelection(.enabled).lineLimit(8)
            }
        case .ready:
            if let note = browser.staleNote {
                Text(note).font(.caption2).foregroundStyle(tk.warn)
            }
            if browser.visible().isEmpty {
                Text("no \(browser.stateFilter.rawValue) issues")
                    .font(.caption).foregroundStyle(tk.t4)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(browser.visible(), id: \.number) { issue in
                        row(issue)
                            .id(issue.number)
                    }
                }
            }
            .onChange(of: browser.selectedNumber) { _, n in
                if let n { proxy.scrollTo(n) }
            }
        }
        .focusable()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handleListKey(press) }
    }

    private func row(_ issue: GhIssue) -> some View {
        HStack(spacing: 6) {
            Circle().fill(issue.isOpen ? tk.ok : tk.t4).frame(width: 6, height: 6)
            Text("#\(issue.number)")
                .font(.caption.monospaced()).foregroundStyle(tk.t3)
            Text(issue.title)
                .font(.caption).foregroundStyle(tk.t1).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issue.number == browser.selectedNumber
                    ? tk.accent.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            model.setFocus(.inspector)
            browser.selectNumber(issue.number)
            listFocused = true
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        if browser.prompt != nil { return handlePromptKey(press) }   // Task 14
        if press.key == .escape { return .ignored }   // zone exit stays global
        if press.key == .downArrow { browser.moveSelection(1); return .handled }
        if press.key == .upArrow { browser.moveSelection(-1); return .handled }
        if press.key == .return {
            if let n = browser.selectedNumber { browser.screen = .detail(n) }
            return .handled
        }
        guard let raw = press.characters.first else { return .ignored }
        switch latinize(raw) {
        case "j": browser.moveSelection(1); return .handled
        case "k": browser.moveSelection(-1); return .handled
        case "/":
            searchVisible = true
            searchFocused = true
            return .handled
        case "o":
            Task { await browser.cycleFilter() }
            return .handled
        case "r":
            Task { await browser.refresh(force: true) }
            return .handled
        case "n":
            model.setIssueScreen(.composer)
            model.selectInspectorTab(.issue)   // bumps issueFocusTick -> title focus
            return .handled
        default:
            return handleActionKey(latinize(raw))   // s/e/c/x/b — Tasks 12-14
        }
    }

    // Placeholder until Tasks 12-14 wire the actions.
    private func handleActionKey(_ ch: Character) -> KeyPress.Result { .ignored }
    private func handlePromptKey(_ press: KeyPress) -> KeyPress.Result { .ignored }
    @ViewBuilder
    private func promptCard(_ prompt: IssueBrowserModel.Prompt) -> some View {
        EmptyView()
    }

    private var footerHints: some View {
        HStack(spacing: 10) {
            KbdBadge(key: "enter", label: "view", tk: tk)
            KbdBadge(key: "n", label: "new", tk: tk)
            KbdBadge(key: "s", label: "session", tk: tk)
            KbdBadge(key: "/", label: "search", tk: tk)
        }
    }
}
```

Примечание: `browser.selectNumber(_:)` — добавить в `IssueBrowserModel` однострочник:

```swift
func selectNumber(_ n: Int) { selectedNumber = n }
```

- [ ] **Step 2: InspectorView** — заменить оба `IssuePane(model: model)` на `IssueBrowserPane(model: model)` (строки 16 и 20).

- [ ] **Step 3: Сборка + тесты.** Run: `swift build && swift test`

- [ ] **Step 4: Ручная проверка** (пользователь запускает app):
`space g l` в сессии git-репо → шторка, список issues; `j`/`k` ходят, `o` меняет фильтр, `/` — поиск, `r` — refresh со спиннером, `n` → композер, esc из композера → список; повторное открытие в течение 2 минут — мгновенно (кеш); `space g i` — по-прежнему сразу композер.

- [ ] **Step 5: Commit** — `feat(covey): issue browser pane — list screen, search, cache wiring`

---

### Task 12: IssueDetailView

**Files:**
- Create: `Sources/covey/Views/IssueDetailView.swift`
- Modify: `Sources/covey/Views/IssueBrowserPane.swift` (подключить + ключ `enter`→detail уже есть; добавить действия)

**Interfaces:**
- Produces: `struct IssueDetailView: View { let issue: GhIssue; let tk: Tokens }` — только отображение; ключи остаются в IssueBrowserPane.
- Consumes: `browser.screen = .detail(n)`, `browser.selectedIssue()`.

- [ ] **Step 1: Создать `IssueDetailView.swift`:**

```swift
import SwiftUI

/// Read-only issue detail: header (number, title, state, author, date,
/// labels) + selectable body. Keys live in IssueBrowserPane.
struct IssueDetailView: View {
    let issue: GhIssue
    let tk: Tokens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("#\(issue.number)")
                        .font(.caption.monospaced()).foregroundStyle(tk.t3)
                    Text(issue.isOpen ? "OPEN" : "CLOSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(issue.isOpen ? tk.ok : tk.t4)
                    Spacer()
                }
                Text(issue.title)
                    .font(.callout.weight(.semibold)).foregroundStyle(tk.t1)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(issue.author).font(.caption2).foregroundStyle(tk.t3)
                    Text(issue.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(tk.t4)
                }
                if !issue.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(issue.labels, id: \.name) { label in
                            Text(label.name)
                                .font(.caption2).foregroundStyle(tk.t2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(tk.surf2, in: Capsule())
                                .overlay(Capsule().strokeBorder(tk.bd2))
                        }
                    }
                }
                Divider()
                Text(issue.body.isEmpty ? "no description" : issue.body)
                    .font(.caption)
                    .foregroundStyle(issue.body.isEmpty ? tk.t4 : tk.t2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
```

- [ ] **Step 2: Подключить в IssueBrowserPane** — в `browserBody` заменить заглушку:

```swift
case .detail(let n):
    if let issue = browser.issues.first(where: { $0.number == n }) {
        detailScreen(issue)
    } else {
        // The issue vanished on a refetch — fall back to the list.
        Color.clear.onAppear { browser.screen = .list }
    }
```

и добавить экран с ключами (тот же `.focusable()`-приём, что у списка):

```swift
@FocusState private var detailFocused: Bool

private func detailScreen(_ issue: GhIssue) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        IssueDetailView(issue: issue, tk: tk)
        if let prompt = browser.prompt { promptCard(prompt) }
        HStack(spacing: 10) {
            KbdBadge(key: "e", label: "edit", tk: tk)
            KbdBadge(key: "s", label: "session", tk: tk)
            KbdBadge(key: "c", label: issue.isOpen ? "close" : "reopen", tk: tk)
            KbdBadge(key: "x", label: "delete", tk: tk)
            KbdBadge(key: "esc", label: "list", tk: tk)
        }
    }
    .padding(8)
    .focusable()
    .focused($detailFocused)
    .onKeyPress(phases: .down) { press in handleDetailKey(press) }
    .onAppear { detailFocused = true }   // screen switch = explicit user action
    .onExitCommand {
        browser.screen = .list
        listFocused = true
    }
}

private func handleDetailKey(_ press: KeyPress) -> KeyPress.Result {
    if browser.prompt != nil { return handlePromptKey(press) }
    if press.key == .escape {
        browser.screen = .list
        listFocused = true
        return .handled
    }
    guard let raw = press.characters.first else { return .ignored }
    return handleActionKey(latinize(raw))
}
```

(Фокус тут по `onAppear` допустим: экран монтируется только по явному действию пользователя, remount-гонок таба нет; список остаётся на tick-сигнале.)

- [ ] **Step 3: Действия `s`/`b` + вход в edit** — реализовать `handleActionKey` (общий для list/detail):

```swift
private func handleActionKey(_ ch: Character) -> KeyPress.Result {
    guard let issue = browser.selectedIssue() else { return .ignored }
    switch ch {
    case "s":
        model.newSessionFromIssue(number: issue.number, title: issue.title)
        return .handled
    case "b":
        if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
        return .handled
    case "e":
        browser.screen = .edit(issue.number)
        return .handled
    case "c", "x":
        return .ignored   // Task 14 wires close/delete prompts
    default:
        return .ignored
    }
}
```

Примечание: в list-экране выделение и есть `selectedIssue()`; в detail номер экрана и `selectedNumber` совпадают (enter из списка ставит оба).

- [ ] **Step 4: Сборка + тесты + ручная проверка:** enter → детали (шапка, лейблы, тело, дата); esc → список; `s` → NewSessionSheet с именем `#N title` и директорией проекта; `b` → браузер.
Run: `swift build && swift test`

- [ ] **Step 5: Commit** — `feat(covey): issue detail screen; session-from-issue and open-in-browser keys`

---

### Task 13: IssueEditView

**Files:**
- Create: `Sources/covey/Views/IssueEditView.swift`
- Modify: `Sources/covey/Views/IssueBrowserPane.swift` (подключить)

**Interfaces:**
- Produces: `struct IssueEditView: View` — форма title/body/labels; сохранение через `browser.saveEdit`, отмена через `browser.screen = .detail(n)`.
- Consumes: `browser.loadLabelsIfNeeded()`, `browser.labels`, `browser.saveEdit(...)` (Task 7), `labelDiff` (Task 2), `VimEditor` (`init(text:modeBadge:tk:startInPreview:focusTick:onSwitchField:)`), `model.inspectorVimBadge`.

- [ ] **Step 1: Создать `IssueEditView.swift`:**

```swift
import SwiftUI

/// Issue editor: title, body (vim), label checklist. Sends only the diff
/// (changed title/body, added/removed labels) via browser.saveEdit.
struct IssueEditView: View {
    @Bindable var model: AppModel
    let issue: GhIssue

    @State private var title: String
    @State private var body_: String
    @State private var picked: Set<String>
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var browser: IssueBrowserModel { model.issueBrowser }

    init(model: AppModel, issue: GhIssue) {
        self.model = model
        self.issue = issue
        _title = State(initialValue: issue.title)
        _body_ = State(initialValue: issue.body)
        _picked = State(initialValue: Set(issue.labels.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("edit #\(issue.number)")
                .font(.caption.monospaced()).foregroundStyle(tk.t3)
            TextField("Title", text: $title)
                .focused($titleFocused)
                .ayuField(tk, focused: titleFocused)
            VimEditor(text: $body_, modeBadge: Binding(
                get: { model.inspectorVimBadge ?? "" },
                set: { model.inspectorVimBadge = $0.isEmpty ? nil : $0 }),
                      tk: tk,
                      onSwitchField: { _ in titleFocused = true })
                .frame(height: 120)
            labelChecklist
            HStack {
                Spacer()
                Button("Cancel") { browser.screen = .detail(issue.number) }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                Button("Save") { save() }
                    .buttonStyle(AyuButton(tk: tk, prominent: true))
                    .disabled(saving ||
                              title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            save()
            return .handled
        }
        .onExitCommand { browser.screen = .detail(issue.number) }
        .task { await browser.loadLabelsIfNeeded() }
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var labelChecklist: some View {
        if browser.labelsLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("loading labels…").font(.caption2).foregroundStyle(tk.t4)
            }
        } else if let labels = browser.labels, !labels.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(labels, id: \.name) { label in
                        labelRow(label.name)
                    }
                }
            }
            .frame(maxHeight: 90)
        }
    }

    private func labelRow(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: picked.contains(name) ? "checkmark.square.fill" : "square")
                .foregroundStyle(picked.contains(name) ? Color.accentColor : .secondary)
            Text(name).font(.caption)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else { return }
        let diff = labelDiff(original: issue.labels.map(\.name),
                             edited: Array(picked))
        saving = true
        Task { @MainActor in
            let ok = await browser.saveEdit(
                number: issue.number,
                title: trimmed == issue.title ? nil : trimmed,
                body: body_ == issue.body ? nil : body_,
                addLabels: diff.add, removeLabels: diff.remove)
            saving = false
            if ok { browser.screen = .detail(issue.number) }
        }
    }
}
```

- [ ] **Step 2: Подключить в IssueBrowserPane** — заменить заглушку:

```swift
case .edit(let n):
    if let issue = browser.issues.first(where: { $0.number == n }) {
        IssueEditView(model: model, issue: issue)
            .id(n)   // fresh @State per issue
    } else {
        Color.clear.onAppear { browser.screen = .list }
    }
```

- [ ] **Step 3: Сборка + тесты + ручная проверка:** `e` из деталей → форма с текущими значениями; лейблы грузятся один раз; правка title/лейблов → Save → тост «issue #N updated», детали обновились; Cancel/esc — без сети.
Run: `swift build && swift test`

- [ ] **Step 4: Commit** — `feat(covey): issue edit screen — title, body, label checklist`

---

### Task 14: инлайн-промпты close/delete

**Files:**
- Modify: `Sources/covey/Views/IssueBrowserPane.swift` (`promptCard`, `handlePromptKey`, ключи `c`/`x` в `handleActionKey`)

**Interfaces:**
- Consumes: `browser.beginClose()/closeSelected(reason:)/reopenSelected()/beginDelete()/deleteConfirmed()/cancelPrompt()`, `browser.prompt`, `browser.actionBusy` (Task 7).

- [ ] **Step 1: Ключи `c`/`x`** — в `handleActionKey` заменить кейс-заглушку:

```swift
case "c":
    if issue.isOpen {
        browser.beginClose()
    } else {
        Task { await browser.reopenSelected() }
    }
    return .handled
case "x":
    browser.beginDelete()
    return .handled
```

- [ ] **Step 2: `promptCard`** — заменить заглушку:

```swift
@ViewBuilder
private func promptCard(_ prompt: IssueBrowserModel.Prompt) -> some View {
    switch prompt {
    case .closeReason(let n):
        statusCard(tk: tk, tint: tk.wait, title: "close #\(n)",
                   spinner: browser.actionBusy) {
            HStack(spacing: 10) {
                KbdBadge(key: "c", label: "completed", tk: tk)
                KbdBadge(key: "n", label: "not planned", tk: tk)
                KbdBadge(key: "esc", label: "cancel", tk: tk)
            }
        }
    case .deleteConfirm(let n):
        statusCard(tk: tk, icon: "trash", tint: tk.err, title: "delete issue #\(n)?",
                   spinner: browser.actionBusy) {
            HStack(spacing: 10) {
                KbdBadge(key: "enter", label: "delete", tk: tk)
                KbdBadge(key: "esc", label: "cancel", tk: tk)
            }
        }
    }
}
```

- [ ] **Step 3: `handlePromptKey`** — заменить заглушку:

```swift
private func handlePromptKey(_ press: KeyPress) -> KeyPress.Result {
    guard !browser.actionBusy else { return .handled }   // swallow while running
    if press.key == .escape {
        browser.cancelPrompt()
        return .handled
    }
    switch browser.prompt {
    case .closeReason:
        guard let raw = press.characters.first else { return .handled }
        switch latinize(raw) {
        case "c": Task { await browser.closeSelected(reason: .completed) }
        case "n": Task { await browser.closeSelected(reason: .notPlanned) }
        default: break
        }
        return .handled
    case .deleteConfirm:
        if press.key == .return {
            Task { await browser.deleteConfirmed() }
        }
        return .handled
    case nil:
        return .ignored
    }
}
```

- [ ] **Step 4: Сборка + тесты + ручная проверка:** `c` на открытом → промпт причин, `c`/`n` закрывает с тостом, список обновился; `c` на закрытом → reopen; `x` → красная карточка, enter удаляет (на чужом репо — тост с ошибкой прав), esc отменяет; во время операции ключи проглатываются.
Run: `swift build && swift test`

- [ ] **Step 5: Commit** — `feat(covey): close-with-reason and delete-confirm prompts`

---

### Task 15: подсказки — StatusBar, HelpOverlay

**Files:**
- Modify: `Sources/covey/Views/StatusBar.swift:62-77` (`hintPairs`)
- Modify: `Sources/covey/Views/HelpOverlay.swift:26,30`

**Interfaces:**
- Consumes: `model.issueScreen`, `model.issueBrowser.screen`, `model.issueBrowser.prompt`.

- [ ] **Step 1: StatusBar** — в `hintPairs`, ветка `focus == .inspector`, заменить блок `if model.inspectorTab == .issue {...}` на:

```swift
if model.inspectorTab == .issue {
    if model.issueScreen == .composer {
        return [("⌘ M", "assign"), ("⌘ O", "browser"), ("enter", "create"),
                ("esc", "issues"), ("⌃h/⌃l", "zones")]
    }
    switch model.issueBrowser.screen {
    case .list:
        return [("enter", "view"), ("s", "session"), ("n", "new"),
                ("o", "state"), ("/", "search"), ("e/c/x", "edit/close/del")]
    case .detail:
        return [("e", "edit"), ("s", "session"), ("c", "close/reopen"),
                ("x", "delete"), ("b", "browser"), ("esc", "list")]
    case .edit:
        return [("enter", "save"), ("esc", "cancel")]
    }
}
```

- [ ] **Step 2: HelpOverlay** — строку 26 дополнить и строку 30 обновить:

```swift
("⌃h/⌃l · s (inspector)", "note/issue tab · tabs/split"),
("j/k · enter · e/c/x · s (issues)", "nav · view · edit/close/delete · session"),
```

```swift
("g", "git: issue · list issues · promote · delete branch · cleanup · return"),
```

(точные строки сверить по месту — файл мог сдвинуться).

- [ ] **Step 3: Сборка + тесты.** Run: `swift build && swift test`

- [ ] **Step 4: Commit** — `feat(covey): issue browser hints in status bar and help`

---

### Task 16: инвалидация после create + финальная верификация

**Files:**
- Modify: `Sources/covey/Views/IssuePane.swift:172-181` (success-ветка `submit`)

**Interfaces:**
- Consumes: `model.issueBrowser.invalidate(root:)` (Task 6).

- [ ] **Step 1: IssuePane.submit** — в ветке `.success` (не `--web`), после `model.clearIssueDraft(forRoot: root)` добавить:

```swift
model.issueBrowser.invalidate(root: root)
```

- [ ] **Step 2: Полный прогон.**
Run: `swift build && swift test`
Expected: все тесты зелёные.

- [ ] **Step 3: Ручной сквозной прогон** (пользователь, чек-лист):
1. `space g l` → список открытых issues; повторное открытие < 2 мин — без сети (мгновенно).
2. `/` фильтрует, `o` циклит open/closed/all, `r` обновляет.
3. enter → детали; `b` → GitHub в браузере.
4. `s` → NewSessionSheet: имя `#N заголовок` (без `:`/`.`), директория проекта; создание работает.
5. `e` → правка title/body/лейблов → Save → тост, данные обновились.
6. `c` → close completed/not planned; `c` на закрытом → reopen.
7. `x` → подтверждение → delete (или внятная ошибка прав).
8. `n` → композер; создание нового issue → возврат в список показывает его (кеш инвалидирован).
9. `space g i` → сразу композер; esc → список.
10. Отключить сеть → `r` → список остаётся, «updated Nm ago — refresh failed».

- [ ] **Step 4: Commit** — `feat(covey): composer create invalidates browser cache`

---

## Self-Review (выполнен)

- **Покрытие спеки:** данные/сервис (T1–4), кеш (T5–6), модель действий (T7), чорд+вязка+префилл (T8–9), UI список/детали/редактор (T10–13), промпты (T14), подсказки (T15), инвалидация от композера + сквозной прогон (T16). Разделы спеки 0–9 закрыты.
- **Плейсхолдеры:** заглушки в T11 (`handleActionKey`/`handlePromptKey`/`promptCard`) — намеренные TDD-скелеты, закрываются T12/T14 с полным кодом. Прочих «TBD» нет.
- **Типы сквозные:** `GhOutcome<T>`, `IssueState`, `CloseReason`, `IssueBrowserModel.Screen/Stage/Prompt`, `selectNumber(_:)` — имена согласованы между задачами.
