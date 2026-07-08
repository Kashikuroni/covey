# Слайс 29 — issue-карточки и WIP-сигналы (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Строки списка issues становятся карточками в анатомии сессионных, с бейджами «работа ведётся» (covey-сессия, локальная ветка, связанный PR) и клавишей `g` для прыжка в сессию.

**Architecture:** PR-сигнал приезжает тем же `gh issue list --json` (новое поле `closedByPullRequestsReferences` → `GhIssue.linkedPRs`); локальные ветки — в `IssueBrowserModel.localBranches` через инжектируемый `fetchBranches` (живая проводка — `AppModel.gitInfo`). Связка issue↔сессия/ветка — чистые матчеры в IssueModels.swift, вычисляются при рендере строки. Карточка — новый глупый (model-free) `IssueCardView`.

**Tech Stack:** Swift 6 (language mode v5) / SwiftUI, gh CLI, XCTest.

**Spec:** `/covey/docs/superpowers/specs/2026-07-07-covey-issue-cards-design.md`
**Working tree:** `/Users/kashikuroni/projects/pets/covey-slice-28` (ветка `slice-28`, слайс 28 не смержен). Baseline: 378 executed / 1 skip / 0 fail.

## Global Constraints

- Весь код, комментарии, идентификаторы — на английском.
- **Git-коммиты делает пользователь.** Шаг «Commit» = предложить сообщение. Никаких git-write команд.
- TDD: скелет → тест RED → реализация → GREEN. Запуск: `swift test --filter <класс>` из корня worktree.
- Ignore SourceKit diagnostics; верить только swift build/test.
- Матчер веток — ровно два правила (спека §2): токен == "N" при токенизации по `/`,`-`,`_`; либо вхождение `#N` с границей токена справа.
- Матчер сессии: имя == `"#N"` или префикс `"#N "` — `#12` не матчит `#123`.
- `relativeAge`: `<60s → "now"`, `<60m → "Xm"`, `<24h → "Xh"`, `<7d → "Xd"`, иначе `"Xw"`.
- Карточка: фон `tk.card`/`tk.cardHover`, рамка `tk.bd`/`tk.bd3`, радиус `Tokens.r`, тень `tk.shadowColor`/`Tokens.shadowRadius`/`Tokens.shadowY`, полоска слева 2pt: selected → `tk.t1`, open → `tk.ok.opacity(0.5)`, closed → `.clear`.
- Лейблов на карточке максимум 3 + `+N`; возраст mono 10 `tk.t4`; превью тела — первая непустая строка body.

---

### Task 1: GhPRRef + linkedPRs в GhIssue

**Files:**
- Modify: `Sources/covey/IssueModels.swift` (struct GhIssue + decode extension)
- Modify: `Sources/covey/IssueService.swift` (константа `issueListFields`)
- Test: `Tests/CoveyAppTests/IssueModelsTests.swift`

**Interfaces:**
- Produces: `struct GhPRRef: Decodable, Equatable { var number: Int; var url: String }`; `GhIssue.linkedPRs: [GhPRRef]` (отсутствие ключа → `[]`); `issueListFields` включает `closedByPullRequestsReferences`.
- Consumes: существующий кастомный `init(from:)` GhIssue.

- [ ] **Step 1: Скелет** — в `IssueModels.swift` перед `GhIssue`:

```swift
/// A PR that will close the issue (gh's closedByPullRequestsReferences).
struct GhPRRef: Decodable, Equatable {
    var number: Int
    var url: String
}
```

В `GhIssue` добавить хранимое поле (после `url`):

```swift
    var linkedPRs: [GhPRRef]
```

В `CodingKeys` добавить кейс:

```swift
        case number, title, body, state, author, labels, updatedAt, url
        case linkedPRs = "closedByPullRequestsReferences"
```

В `init(from:)` после `url = ...`:

```swift
        linkedPRs = (try? c.decodeIfPresent([GhPRRef].self, forKey: .linkedPRs)) ?? []
```

В `IssueService.swift` обновить константу:

```swift
let issueListFields =
    "number,title,body,state,author,labels,updatedAt,url,closedByPullRequestsReferences"
```

ВНИМАНИЕ: тестовый memberwise-инициализатор GhIssue в
`Tests/CoveyAppTests/IssueBrowserModelTests.swift` (JSON round-trip) перестанет
компилироваться/давать полный объект — добавить в его словарь/вызовы параметр
`linkedPRs: [GhPRRef] = []` с дефолтом, чтобы существующие вызовы не менялись.
Прочитай текущий вид этого init и сохрани его механику (round-trip через decode).

- [ ] **Step 2: Тест** — в `IssueModelsTests.swift`:

```swift
func testParseIssuesDecodesLinkedPRs() throws {
    let json = Data("""
    [{"number":5,"title":"t","body":"","state":"OPEN","author":null,
      "labels":[],"updatedAt":"2026-07-01T00:00:00Z",
      "url":"https://github.com/o/r/issues/5",
      "closedByPullRequestsReferences":[
        {"id":"PR1","number":41,"url":"https://github.com/o/r/pull/41"}]}]
    """.utf8)
    let issues = try XCTUnwrap(parseIssues(json))
    XCTAssertEqual(issues[0].linkedPRs,
                   [GhPRRef(number: 41, url: "https://github.com/o/r/pull/41")])
}

func testParseIssuesMissingPRKeyIsEmpty() throws {
    // The Task-1 fixture (issuesJSON) has no closedByPullRequestsReferences key.
    let issues = try XCTUnwrap(parseIssues(Self.issuesJSON))
    XCTAssertEqual(issues[0].linkedPRs, [])
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueModelsTests` — компиляция падает (нет GhPRRef/linkedPRs).

- [ ] **Step 4: Реализация по Step 1 + правка тестового init.**

- [ ] **Step 5: PASS + полный прогон.** Run: `swift test` Expected: 380/1/0 (378 + 2 новых).

- [ ] **Step 6: Commit** — предложить: `feat(covey): linked PR references on GhIssue`

---

### Task 2: матчеры + relativeAge + bodyPreview

**Files:**
- Modify: `Sources/covey/IssueModels.swift`
- Test: `Tests/CoveyAppTests/IssueModelsTests.swift`

**Interfaces:**
- Produces:
  `func sessionNameMatchesIssue(_ name: String, number: Int) -> Bool`;
  `func branchMatchesIssue(_ branch: String, number: Int) -> Bool`;
  `func relativeAge(from: Date, to: Date) -> String`;
  `func bodyPreview(_ body: String) -> String?` (nil когда body пуст/из одних пустых строк).

- [ ] **Step 1: Скелеты** — в `IssueModels.swift`:

```swift
/// True for covey's session-from-issue naming: "#N" exactly or "#N ..." —
/// "#12" must not match "#123".
func sessionNameMatchesIssue(_ name: String, number: Int) -> Bool { false }

/// Exactly two rules (spec §2): a /-,-,_-token equals "N", or the name
/// contains "#N" with a token boundary on the right.
func branchMatchesIssue(_ branch: String, number: Int) -> Bool { false }

/// Compact age for the card: now / Xm / Xh / Xd / Xw.
func relativeAge(from: Date, to: Date) -> String { "" }

/// First non-empty body line for the card's preview row.
func bodyPreview(_ body: String) -> String? { nil }
```

- [ ] **Step 2: Тесты:**

```swift
func testSessionNameMatchesIssue() {
    XCTAssertTrue(sessionNameMatchesIssue("#12 fix scroll", number: 12))
    XCTAssertTrue(sessionNameMatchesIssue("#12", number: 12))
    XCTAssertFalse(sessionNameMatchesIssue("#123 other", number: 12))
    XCTAssertFalse(sessionNameMatchesIssue("fix #12", number: 12))
    XCTAssertFalse(sessionNameMatchesIssue("", number: 12))
}

func testBranchMatchesIssue() {
    XCTAssertTrue(branchMatchesIssue("12-fix", number: 12))
    XCTAssertTrue(branchMatchesIssue("issue/12", number: 12))
    XCTAssertTrue(branchMatchesIssue("fix-12", number: 12))
    XCTAssertTrue(branchMatchesIssue("feat_12_x", number: 12))
    XCTAssertTrue(branchMatchesIssue("hotfix/#12-scroll", number: 12))
    XCTAssertFalse(branchMatchesIssue("112-fix", number: 12))
    XCTAssertFalse(branchMatchesIssue("1234", number: 12))
    XCTAssertFalse(branchMatchesIssue("fix-121", number: 12))
    XCTAssertFalse(branchMatchesIssue("#123", number: 12))
    XCTAssertFalse(branchMatchesIssue("main", number: 12))
}

func testRelativeAge() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-30), to: t), "now")
    XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-300), to: t), "5m")
    XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-7200), to: t), "2h")
    XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-3 * 86_400), to: t), "3d")
    XCTAssertEqual(relativeAge(from: t.addingTimeInterval(-15 * 86_400), to: t), "2w")
}

func testBodyPreview() {
    XCTAssertEqual(bodyPreview("first line\nsecond"), "first line")
    XCTAssertEqual(bodyPreview("\n\n  \nreal text\nmore"), "real text")
    XCTAssertNil(bodyPreview(""))
    XCTAssertNil(bodyPreview("   \n \n"))
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueModelsTests`

- [ ] **Step 4: Реализация:**

```swift
func sessionNameMatchesIssue(_ name: String, number: Int) -> Bool {
    let tag = "#\(number)"
    return name == tag || name.hasPrefix("\(tag) ")
}

func branchMatchesIssue(_ branch: String, number: Int) -> Bool {
    let n = String(number)
    let tokens = branch.split { "/-_".contains($0) }.map(String.init)
    if tokens.contains(n) { return true }
    // "#N" with a token boundary on the right (e.g. "hotfix/#12-scroll").
    let tag = "#\(n)"
    var search = branch[...]
    while let r = search.range(of: tag) {
        let after = r.upperBound
        if after == branch.endIndex || "/-_".contains(branch[after]) { return true }
        search = branch[after...]
    }
    return false
}

func relativeAge(from: Date, to: Date) -> String {
    let s = Int(to.timeIntervalSince(from))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    if s < 7 * 86_400 { return "\(s / 86_400)d" }
    return "\(s / (7 * 86_400))w"
}

func bodyPreview(_ body: String) -> String? {
    body.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}
```

Примечание к `branchMatchesIssue`: цикл по вхождениям `#N` нужен, потому что
первое вхождение может быть `#123` (граница не пройдена), а дальше — честный
`#12-`; негативный кейс `#123` для N=12 держится границей токена.

- [ ] **Step 5: PASS + полный прогон.** Run: `swift test`

- [ ] **Step 6: Commit** — `feat(covey): issue↔session/branch matchers, relative age, body preview`

---

### Task 3: IssueBrowserModel.localBranches

**Files:**
- Modify: `Sources/covey/IssueBrowserModel.swift`
- Modify: `Sources/covey/AppModel.swift` (живая проводка fetchBranches)
- Test: `Tests/CoveyAppTests/IssueBrowserModelTests.swift`

**Interfaces:**
- Produces: `private(set) var localBranches: [String]`; init-параметр
  `fetchBranches: @escaping (String) async -> [String] = { _ in [] }`.
- Consumes: `AppModel.gitInfo(_ dir:) async` (возвращает кортеж с `.branches`).

- [ ] **Step 1: Скелет** — в классе `IssueBrowserModel`:

```swift
    /// Local branch names of the current root — the card's ⎇ WIP signal.
    private(set) var localBranches: [String] = []

    var fetchBranches: (String) async -> [String]
```

Init получает новый параметр (с дефолтом, существующие вызовы не меняются):

```swift
         fetchBranches: @escaping (String) async -> [String] = { _ in [] },
```

(вставить между `runMutation` и `toast`, присвоить в теле).

- [ ] **Step 2: Тесты** — в `IssueBrowserModelFlowTests`:

```swift
func testOpenPopulatesLocalBranches() async {
    var m: IssueBrowserModel!
    m = IssueBrowserModel(
        fetchIssues: { _, _ in .success([self.issue(1, "a")]) },
        fetchBranches: { _ in ["main", "12-fix"] },
        now: { self.t0 })
    await m.open(root: "/r", dir: "/r")
    XCTAssertEqual(m.localBranches, ["main", "12-fix"])
}

func testStaleBranchesDoNotApplyAfterRootSwitch() async {
    // Park /a's branch fetch; open /b; the late /a result must not land.
    var release: CheckedContinuation<Void, Never>?
    let m = IssueBrowserModel(
        fetchIssues: { _, _ in .success([]) },
        fetchBranches: { dir in
            if dir == "/a" {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    release = c
                }
                return ["a-late"]
            }
            return ["b-branch"]
        },
        now: { self.t0 })
    async let first: Void = m.open(root: "/a", dir: "/a")
    // Wait until /a's fetch is parked.
    while release == nil { await Task.yield() }
    await m.open(root: "/b", dir: "/b")
    XCTAssertEqual(m.localBranches, ["b-branch"])
    release?.resume()
    await first
    XCTAssertEqual(m.localBranches, ["b-branch"])   // /a's late result dropped
}
```

- [ ] **Step 3: FAIL.** Run: `swift test --filter IssueBrowserModelFlowTests` (нет `fetchBranches`).

- [ ] **Step 4: Реализация.** В начало `open(root:dir:)` (после присвоения
`self.root`/`self.dir`) добавить загрузку веток с гардом актуальности:

```swift
        let branchDir = dir
        Task {
            let fetched = await fetchBranches(branchDir)
            // A late result for a switched-away root must not land.
            if self.dir == branchDir { self.localBranches = fetched }
        }
```

и в `refresh(force:)` после guard-строки:

```swift
        let branchDir = dir!
        Task {
            let fetched = await fetchBranches(branchDir)
            if self.dir == branchDir { self.localBranches = fetched }
        }
```

Примечание: обе вставки — fire-and-forget Task, list-фетч не ждёт веток.
В тесте `testStaleBranchesDoNotApplyAfterRootSwitch` порядок гарантируется
континуацией, а не сном. Если компилятор потребует `[weak self]`/explicit
self в Task — добавить, поведение сохранить. Если fire-and-forget делает
тест flaky (assert до завершения Task), допустимо сделать загрузку веток
awaited-строкой внутри open/refresh (`localBranches = await ...` с тем же
гардом) — выбор задокументировать в отчёте.

Живая проводка — в `AppModel.init`, рядом с `issueBrowser.toast = ...`:

```swift
        issueBrowser.fetchBranches = { [weak self] dir in
            await self?.gitInfo(dir).branches ?? []
        }
```

(Проверь фактическую форму результата `gitInfo` — в NewSessionSheet берут
`info.branches`; используй то же поле.)

- [ ] **Step 5: PASS + полный прогон.** Run: `swift test`

- [ ] **Step 6: Commit** — `feat(covey): local branches feed for issue WIP badges`

---

### Task 4: общий стиль статуса сессии

**Files:**
- Create: `Sources/covey/Views/SessionStatusStyle.swift`
- Modify: `Sources/covey/Views/SessionListView.swift:174-188` (приватные statusLabel/statusLabelColor → общие)

**Interfaces:**
- Produces: `func sessionStatusLabel(_ status: Status) -> String`;
  `func sessionStatusTint(_ status: Status, tk: Tokens) -> Color`.
- Consumes: `Status` (CoveyKit), `Tokens`.

- [ ] **Step 1: Создать `Sources/covey/Views/SessionStatusStyle.swift`:**

```swift
import SwiftUI
import CoveyKit

/// Status → label/tint mapping shared by the session list cards and the
/// issue cards' session badge.
func sessionStatusLabel(_ status: Status) -> String {
    switch status {
    case .running: return "running"
    case .waiting: return "waiting"
    case .idle: return "idle"
    }
}

func sessionStatusTint(_ status: Status, tk: Tokens) -> Color {
    switch status {
    case .running: return tk.run.opacity(0.8)
    case .waiting: return tk.wait
    case .idle: return tk.t4
    }
}
```

- [ ] **Step 2: SessionListView** — удалить приватные `statusLabel(_:)` и
`statusLabelColor(_:)` (строки ~174-188), заменить оба вызова в `card(_:)`:
`statusLabel(status)` → `sessionStatusLabel(status)`,
`statusLabelColor(status)` → `sessionStatusTint(status, tk: tk)`.

- [ ] **Step 3: Сборка + прогон.** Run: `swift build && swift test` Expected: зелёно, поведение 1:1.

- [ ] **Step 4: Commit** — `refactor(covey): shared session status label/tint`

---

### Task 5: IssueCardView + карточки в списке + `g`

**Files:**
- Create: `Sources/covey/Views/IssueCardView.swift`
- Modify: `Sources/covey/Views/IssueBrowserPane.swift` (row → карточка, `g` в handleActionKey, зазор рядов)
- Modify: `Sources/covey/Views/StatusBar.swift` (detail-хинты + `g`)
- Modify: `Sources/covey/Views/HelpOverlay.swift` (строка issues + `g`)

**Interfaces:**
- Produces: `struct IssueWip: Equatable { var sessionName: String?; var sessionTint: Color?; var branch: String?; var prNumber: Int? }`;
  `struct IssueCardView: View` с init `(issue: GhIssue, selected: Bool, age: String, wip: IssueWip, tk: Tokens, onSessionTap: (() -> Void)?)`.
- Consumes: матчеры и `relativeAge`/`bodyPreview` (Task 2), `localBranches` (Task 3), `sessionStatusTint` (Task 4), `model.sessions`, `sessionRoot(_:)` (существующий хелпер covey), `model.statusByName`, `browser.now`.

- [ ] **Step 1: Создать `Sources/covey/Views/IssueCardView.swift`:**

```swift
import SwiftUI

/// Work-in-progress signals for one issue, precomputed by the pane —
/// the card itself is model-free and dumb.
struct IssueWip: Equatable {
    var sessionName: String?
    var sessionTint: Color?
    var branch: String?
    var prNumber: Int?

    var isEmpty: Bool { sessionName == nil && branch == nil && prNumber == nil }
}

/// Issue row in the session-card idiom: card fill, hairline border,
/// 2pt state stripe, shadow. Rows collapse when empty.
struct IssueCardView: View {
    let issue: GhIssue
    let selected: Bool
    let age: String
    let wip: IssueWip
    let tk: Tokens
    var onSessionTap: (() -> Void)?

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(issue.number)")
                    .font(mono(13, .medium)).foregroundStyle(tk.t3)
                Text(issue.title)
                    .font(.caption)
                    .foregroundStyle(selected ? tk.t1 : tk.t2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(age).font(mono(10)).foregroundStyle(tk.t4)
            }
            if let preview = bodyPreview(issue.body) {
                Text(preview)
                    .font(.caption2).foregroundStyle(tk.t4).lineLimit(1)
            }
            if !issue.labels.isEmpty || !issue.author.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3), id: \.name) { label in
                        Text(label.name)
                            .font(.caption2).foregroundStyle(tk.t2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(tk.surf2, in: Capsule())
                            .overlay(Capsule().strokeBorder(tk.bd2))
                    }
                    if issue.labels.count > 3 {
                        Text("+\(issue.labels.count - 3)")
                            .font(.caption2).foregroundStyle(tk.t4)
                    }
                    Spacer(minLength: 4)
                    if !issue.author.isEmpty {
                        Text(issue.author).font(.caption2).foregroundStyle(tk.t4)
                    }
                }
            }
            if !wip.isEmpty {
                HStack(spacing: 8) {
                    if let name = wip.sessionName {
                        HStack(spacing: 3) {
                            Text("▸").font(mono(10))
                            Text(name).font(mono(10)).lineLimit(1)
                        }
                        .foregroundStyle(wip.sessionTint ?? tk.t3)
                        .contentShape(Rectangle())
                        .onTapGesture { onSessionTap?() }
                    }
                    if let branch = wip.branch {
                        HStack(spacing: 3) {
                            Text("⎇").font(.system(size: 10))
                            Text(branch).font(mono(10)).lineLimit(1)
                        }
                        .foregroundStyle(tk.t3)
                    }
                    if let pr = wip.prNumber {
                        Text("⇄ #\(pr)").font(mono(10)).foregroundStyle(tk.t3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(selected ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? tk.t1 : (issue.isOpen ? tk.ok.opacity(0.5) : .clear))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .shadow(color: tk.shadowColor, radius: Tokens.shadowRadius, y: Tokens.shadowY)
    }
}
```

- [ ] **Step 2: IssueBrowserPane — карточки.** Заменить тело `row(_:)`
(строки ~210-230) на:

```swift
    private func row(_ issue: GhIssue) -> some View {
        IssueCardView(issue: issue,
                      selected: issue.number == browser.selectedNumber,
                      age: relativeAge(from: issue.updatedAt, to: browser.now()),
                      wip: wip(for: issue),
                      tk: tk,
                      onSessionTap: { jumpToSession(of: issue) })
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                browser.selectNumber(issue.number)
                listFocused = true
            }
    }

    /// WIP signals for one row: live covey session in this root, first
    /// matching local branch, first linked PR.
    private func wip(for issue: GhIssue) -> IssueWip {
        let session = sessionForIssue(issue)
        return IssueWip(
            sessionName: session?.name,
            sessionTint: session.map {
                sessionStatusTint(model.statusByName[$0.name] ?? .idle, tk: tk)
            },
            branch: browser.localBranches.first {
                branchMatchesIssue($0, number: issue.number)
            },
            prNumber: issue.linkedPRs.first?.number)
    }

    private func sessionForIssue(_ issue: GhIssue) -> Session? {
        guard let root else { return nil }
        return model.sessions.first {
            sessionRoot($0) == root && sessionNameMatchesIssue($0.name, number: issue.number)
        }
    }

    private func jumpToSession(of issue: GhIssue) {
        guard let session = sessionForIssue(issue) else { return }
        Task { @MainActor in
            await model.select(session.name)
            model.apply(.enterTerminal)
        }
    }
```

`Session` и `sessionRoot` — проверь импорты/доступность (SessionListView
использует обоих; `import CoveyKit` в пейне уже есть). В `rows` VStack
поменять `spacing: 1` → `spacing: 4` и добавить `.padding(.horizontal, 1)`
если тень клипуется (проверь визуально при ручном прогоне; если нет —
не добавляй).

- [ ] **Step 3: `g` в handleActionKey** — новый кейс перед `default`:

```swift
        case "g":
            guard let issue = browser.selectedIssue(),
                  sessionForIssue(issue) != nil else { return .ignored }
            jumpToSession(of: issue)
            return .handled
```

Примечание: `guard let issue = browser.selectedIssue()` уже стоит в начале
`handleActionKey` — используй существующую переменную `issue`, кейс сведётся к:

```swift
        case "g":
            guard sessionForIssue(issue) != nil else { return .ignored }
            jumpToSession(of: issue)
            return .handled
```

- [ ] **Step 4: Хинты.** `StatusBar.swift`, detail-набор (внутри switch
`model.issueBrowser.screen`, кейс `.detail`) — добавить `("g", "session ↗")`
после `("s", "session")`:

```swift
    case .detail:
        return [("e", "edit"), ("s", "session"), ("g", "session ↗"),
                ("c", "close/reopen"), ("x", "delete"), ("b", "browser"),
                ("esc", "list")]
```

`HelpOverlay.swift` — строку issues дополнить `g`:

```swift
("j/k · enter · e/c/x · s/g (issues)", "nav · view · edit/close/delete · session new/jump"),
```

(точную текущую строку сверь по файлу — она могла сдвинуться).

- [ ] **Step 5: Сборка + прогон + ручная проверка.**
Run: `swift build && swift test` Expected: зелёно.
Руками: карточки в списке (фон/рамка/полоска/тень как у сессий), возраст,
превью, чипы, `+N`; issue со «своей» сессией показывает `▸ имя` цветом
статуса; ветка `⎇`; PR `⇄ #N`; `g` прыгает в сессию с фокусом терминала;
клик по бейджу — то же; выделение карточки читается.

- [ ] **Step 6: Commit** — `feat(covey): issue cards with WIP badges and g-jump`

---

### Task 6: финальная верификация

**Files:** нет новых правок (только фиксы по находкам).

- [ ] **Step 1: Полный прогон.** Run: `swift build && swift test` Expected: все зелёные, 0 fail.

- [ ] **Step 2: Ручной сквозной чек-лист:**
1. `space g l` → карточки; j/k ходят, выделение читается (cardHover + полоска t1).
2. Открытый issue — полоска `tk.ok`; закрытый (фильтр `o`) — без полоски.
3. Issue с сессией `#N …` в этом проекте → бейдж `▸`, цвет = статус сессии; `g` и клик по бейджу прыгают в сессию (фокус в терминале).
4. Ветка `N-…`/`…-N`/`issue/N` в репо → бейдж `⎇` с именем.
5. Issue с привязанным PR → `⇄ #PR`.
6. Пустое body → нет строки превью; >3 лейблов → `+N`; возраст меняется по issue.
7. Детали: хинт `g session ↗` в StatusBar; `g` работает из деталей.
8. Переключение проекта с открытым списком → карточки и ветки нового root.

- [ ] **Step 3: Commit** — финального коммита нет; пользователь коммитит слайс целиком.

---

## Self-Review (выполнен)

- **Покрытие спеки:** §1 данные (T1, T3), §2 матчеры (T2), §3 карточка (T4, T5), §4 клавиши/хинты (T5), §5 тесты (T1-T3 юнит, T5-T6 руками). Пробелов нет.
- **Плейсхолдеры:** нет; все шаги с полным кодом.
- **Типы сквозные:** `GhPRRef`/`linkedPRs` (T1) ↔ `wip(for:)` (T5); `fetchBranches`/`localBranches` (T3) ↔ T5; `sessionStatusTint` (T4) ↔ T5; `relativeAge`/`bodyPreview`/матчеры (T2) ↔ T5/карточка.
