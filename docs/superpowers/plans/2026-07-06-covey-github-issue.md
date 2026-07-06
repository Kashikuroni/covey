# Слайс 24 — `space g i`: GitHub issue через gh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `space g i` открывает композер title/body и файлит issue через `gh issue create` в директории выбранной сессии; URL — в клипборд.

**Architecture:** GUI-only порт amux modal_issue: чистый `IssueService` (Process поверх gh, async), `Modal.issue(dir)` + `IssueSheet` со стадиями editing/creating/done/failed. Демон и протокол не трогаются.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, AppKit (NSPasteboard), XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-06-covey-github-issue-design.md`.
- Весь код и коммиты на английском.
- `swift test` перед каждым коммитом — 0 failures.
- Git-коммиты выполняет пользователь.
- Живой `gh` из тестов не вызывается.
- SourceKit-фантомам не верить — верить `swift build`/`swift test`.

---

### Task 1: IssueService + parseIssueURL

**Files:**
- Create: `Sources/covey/IssueService.swift`
- Test: `Tests/CoveyAppTests/IssueServiceTests.swift` (новый)

**Interfaces:**
- Produces: `func parseIssueURL(_ stdout: String) -> String?`;
  `enum IssueService { static func create(dir: String, title: String, body: String) async -> IssueOutcome }` (enum .success(url:)/.failure(message:) — `Result`'s failure must be an Error).

- [ ] **Step 1: Падающий тест**

Создать `Tests/CoveyAppTests/IssueServiceTests.swift`:

```swift
import XCTest
@testable import covey

final class IssueServiceTests: XCTestCase {
    func testParseIssueURLTakesLastNonEmptyLine() {
        XCTAssertEqual(parseIssueURL("https://github.com/o/r/issues/7\n"),
                       "https://github.com/o/r/issues/7")
        // gh may print progress lines first; the URL is the last one.
        XCTAssertEqual(parseIssueURL("Creating issue in o/r\n\nhttps://github.com/o/r/issues/8\n"),
                       "https://github.com/o/r/issues/8")
        XCTAssertNil(parseIssueURL(""))
        XCTAssertNil(parseIssueURL("  \n \n"))
    }
}
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter IssueServiceTests 2>&1 | grep error | head -2`
Expected: `cannot find 'parseIssueURL' in scope`.

- [ ] **Step 3: Реализация**

Создать `Sources/covey/IssueService.swift`:

```swift
import Foundation

/// The new issue's URL from `gh issue create` stdout: gh prints it as the
/// last line (progress chatter may precede it). Nil when there is none.
func parseIssueURL(_ stdout: String) -> String? {
    let line = stdout.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.last { !$0.isEmpty }
    return line
}

/// Files a GitHub issue with the `gh` CLI (port of git.rs
/// spawn_issue_create). A network call — always awaited off the UI.
enum IssueService {
    /// .success = the created issue's URL; .failure = a display-ready error.
    static func create(dir: String, title: String, body: String) async -> IssueOutcome {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // Arguments go straight to gh — nothing passes through a shell.
            p.arguments = ["gh", "issue", "create", "--title", title, "--body", body]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                return .failure("gh CLI not found — install it (brew install gh), then `gh auth login`")
            }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(msg.isEmpty ? "gh issue create failed" : msg)
            }
            guard let url = parseIssueURL(String(decoding: stdout, as: UTF8.self)) else {
                return .failure("issue created, but gh printed no URL — check GitHub")
            }
            return .success(url)
        }.value
    }
}
```

ВНИМАНИЕ: `/usr/bin/env gh …` упадёт в `try p.run()` только если нет
`env`; отсутствие gh даёт код 127 и пустой stdout — сообщение «gh CLI
not found…» должно покрывать ОБА пути. Поэтому после `waitUntilExit`
добавить перед guard:

```swift
            if p.terminationStatus == 127 {
                return .failure("gh CLI not found — install it (brew install gh), then `gh auth login`")
            }
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter IssueServiceTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/IssueService.swift Tests/CoveyAppTests/IssueServiceTests.swift
git commit -m "feat(covey): IssueService - gh issue create wrapper"
```

---

### Task 2: Роутинг `space g i` + Modal.issue + гарды

**Files:**
- Modify: `Sources/covey/KeyRouter.swift`
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/covey/Views/Sheets.swift` (Modal.id + заглушка IssueSheet)
- Modify: `Sources/covey/Views/ContentView.swift`
- Modify: `Sources/covey/Views/WhichKeyView.swift`
- Modify: `Sources/covey/Views/HelpOverlay.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`, `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Produces: `KeyAction.createIssue`; `Modal.issue(String)`;
  `AppModel.showToast(_ message: String)` (нужен Task 3 для тоста после
  Esc-hide).

- [ ] **Step 1: Падающие тесты**

`Tests/CoveyAppTests/KeyRouterTests.swift` — в конец класса:

```swift
    func testGitIssueChord() {
        XCTAssertEqual(KeyRouter.route(key("i"), context: ctx(mode: .leader(.git))),
                       .createIssue)
    }
```

`Tests/CoveyAppTests/AppModelChromeTests.swift` — в конец класса:

```swift
    @MainActor
    func testCreateIssueGuards() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "no session")

        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")

        // No git info yet -> guard toast, no modal.
        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "not a git repo")
        XCTAssertNil(model.modal)

        // Git info present -> the composer opens on the session's dir.
        // (deliver gitChanged into the model exactly the way the existing
        // testGitActionGuardsAndGitChangedEvent in this file does)
        model.apply(.createIssue)
        XCTAssertEqual(model.modal, .issue("/tmp"))

        daemon.registry.kill(name: "agent")
    }
```

ВНИМАНИЕ: комментарий про gitChanged — указание: приём доставки git-инфо
в модель скопировать из `testGitActionGuardsAndGitChangedEvent` (этот же
файл), не изобретать свой.

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter "testGitIssueChord|testCreateIssueGuards" 2>&1 | grep error | head -3`
Expected: `no member 'createIssue'`.

- [ ] **Step 3: Реализация**

`Sources/covey/KeyRouter.swift`:
- `KeyAction` + `case createIssue` (после `openRecent`);
- `routeLeader` + `case (.git, "i"): return .createIssue`.

`Sources/covey/AppModel.swift`:
- `Modal` + `case issue(String)`;
- в `apply`, рядом с git-кейсами:

```swift
        case .createIssue:
            inputMode = .normal
            guard let s = selectedSession() else { toast = "no session"; return }
            if s.git == nil { toast = "not a git repo"; return }
            modal = .issue(s.dir)
```

- публичный тост (рядом с reconnect):

```swift
    /// Sheets fire-and-forget outcomes (issue created after Esc-hide, …).
    public func showToast(_ message: String) { toast = message }
```

`Sources/covey/Views/Sheets.swift`:
- `Modal.id` + `case .issue(let dir): return "issue-\(dir)"`;
- заглушка (Task 3 заменит):

```swift
// Replaced by the real composer in the next task.
struct IssueSheet: View {
    let model: AppModel
    let dir: String
    var body: some View { Text("issue").padding(40) }
}
```

`Sources/covey/Views/ContentView.swift` — sheet-switch:

```swift
            case .issue(let dir): IssueSheet(model: model, dir: dir)
```

`Sources/covey/Views/WhichKeyView.swift`, группа git — заменить строку i:

```swift
            Row(key: "i", label: "create github issue", implemented: true),
```

`Sources/covey/Views/HelpOverlay.swift`, строка leader g:

```swift
            ("g", "git: promote · delete branch · cleanup · return to root · issue"),
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter "KeyRouterTests|AppModelChromeTests" 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/KeyRouter.swift Sources/covey/AppModel.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/WhichKeyView.swift Sources/covey/Views/HelpOverlay.swift Tests/CoveyAppTests/KeyRouterTests.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): space g i routes to the issue composer (stub sheet)"
```

---

### Task 3: IssueSheet — композер со стадиями

**Files:**
- Modify: `Sources/covey/Views/Sheets.swift` (заглушка → композер)
- Test: полный `swift test`

**Interfaces:**
- Consumes: `IssueService.create(dir:title:body:)`, `parseIssueURL`
  (Task 1), `Modal.issue` + `showToast` (Task 2), `ayuField(_:focused:)`,
  `collapseHome`.

- [ ] **Step 1: Композер**

Заменить заглушку в `Sources/covey/Views/Sheets.swift`:

```swift
/// GitHub-issue composer (port of amux modal_issue): title + body, filed
/// via `gh issue create` in the session's dir. After submit the sheet shows
/// the async stage; Esc mid-flight hides it and the URL still lands in the
/// clipboard (with a toast).
struct IssueSheet: View {
    let model: AppModel
    let dir: String

    enum Stage: Equatable {
        case editing, creating
        case done(String)
        case failed(String)
    }

    @State private var title = ""
    @State private var body_ = ""
    @State private var stage: Stage = .editing
    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch stage {
            case .editing: editor
            case .creating:
                Text("creating issue…").font(.headline)
                Text("esc hide — gh keeps running")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .done(let url):
                Label("issue created", systemImage: "checkmark")
                    .font(.headline).foregroundStyle(tk.ok)
                Text(url).font(.caption.monospaced()).textSelection(.enabled)
                Text("(copied to clipboard) · any key to close")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .failed(let err):
                Label("issue not created", systemImage: "xmark")
                    .font(.headline).foregroundStyle(tk.err)
                Text(err).font(.caption).foregroundStyle(tk.err)
                    .textSelection(.enabled)
                Text("any key to close").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { _ in
            // Terminal stages close on any key.
            switch stage {
            case .done, .failed: model.modal = nil; return .handled
            default: return .ignored
            }
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift), stage == .editing else { return .ignored }
            submit()
            return .handled
        }
        .onExitCommand { model.modal = nil }   // creating: gh keeps running
        .onAppear { titleFocused = true }
    }

    private var editor: some View {
        Group {
            Text("New issue").font(.headline)
            Text("in: \(collapseHome(dir))")
                .font(.caption.monospaced()).foregroundStyle(tk.t3).lineLimit(1)
            TextField("Title", text: $title)
                .focused($titleFocused)
                .ayuField(tk, focused: titleFocused)
                .onSubmit { bodyFocused = true }
            TextEditor(text: $body_)
                .focused($bodyFocused)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 140)
                .background(tk.surf2, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(bodyFocused ? tk.accent.opacity(0.7) : tk.bd2))
                .tint(tk.accent)
            HStack {
                Text("⇧enter create · tab field · esc cancel")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Create") { submit() }
                    .buttonStyle(.glassProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        stage = .creating
        let body = body_
        let dir = dir
        Task { @MainActor in
            let result = await IssueService.create(dir: dir, title: t, body: body)
            switch result {
            case .success(let url):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                if model.modal == .issue(dir) {
                    stage = .done(url)
                } else {
                    model.showToast("issue created — URL copied")
                }
            case .failure(let err):
                if model.modal == .issue(dir) {
                    stage = .failed(err)
                } else {
                    model.showToast("issue failed: \(err)")
                }
            }
        }
    }
}
```

Примечания:
- `body_` — SwiftUI View уже имеет `body`; поле нельзя назвать так же.
- Tab между полями отдаёт системная фокус-цепочка (два фокусируемых
  поля в шите) — отдельный хендлер не нужен; если Tab в TextEditor
  вставляет таб — добавить `.onKeyPress(.tab)` на TextEditor:
  `bodyFocused = false; titleFocused = true; return .handled`.
- Пустой title: Create disabled + submit guard.

- [ ] **Step 2: Полный прогон**

Run: `swift build 2>&1 | grep -c error:; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 ошибок, 0 failures.

- [ ] **Step 3: Commit (user)**

```bash
git add Sources/covey/Views/Sheets.swift
git commit -m "feat(covey): issue composer sheet - stages, clipboard, esc-hide"
```

---

### Task 4: Смоук (user) + docs commit

Рестарт демона НЕ нужен (GUI-only).

- [ ] **Step 1: Смоук по спеке §5**

1. Сессия в репо с github-remote → `space g i`: композер, `in: ~/путь`,
   title в фокусе.
2. Tab → body (многострочный), `⇧Enter` → «creating…» → «✓ issue
   created» + URL; URL в клипборде; любой key закрывает; issue на
   GitHub существует.
3. Репо без remote/auth → «✕ issue not created» + текст gh.
4. Сессия вне git → тост «not a git repo».
5. Esc во время creating → шит закрыт; по завершении — тост, URL в
   клипборде.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/plans/2026-07-06-covey-github-issue.md
git commit -m "docs: slice 24 implementation plan — github issue"
```
