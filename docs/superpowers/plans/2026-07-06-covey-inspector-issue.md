# Слайс 25 — инспектор Note/Issue, драфты, window-чорды Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue-композер переезжает из модалки в правую шторку рядом с note (табы/сплит, per-project драфт, ⌘-чорды с футер-подсказками), плюс leader-группа `space w` для скрытия панелей.

**Architecture:** GUI-only. Инспектор получает зонные табы Note/Issue и два режима (tabs / vsplit, тогл `s`); новый `IssuePane` наследует логику стадий из IssueSheet; драфт `{title, body, assignMe}` живёт в `PersistedState.issueDrafts[sessionRoot]`. Чорды зоны inspector (⌃h/l — табы, ⌃j/k — панели сплита) перекрывают глобальные только внутри зоны.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-06-covey-inspector-issue-design.md`.
- Весь код и коммиты на английском.
- `swift test` перед каждым коммитом — 0 failures.
- Git-коммиты выполняет пользователь.
- Живой `gh` из тестов не вызывается; `IssueService`/`parseIssueURL`/`issueCreateArgs` не меняются.
- SourceKit-фантомам не верить — верить `swift build`/`swift test`.
- ВНИМАНИЕ: пользователь параллельно добавил themeRestart-код — при матчинге строк смотреть текущий файл, якоря в плане могли сместиться.

---

### Task 1: PersistedState — IssueDraft + inspectorSplit

**Files:**
- Modify: `Sources/CoveyKit/PersistedState.swift`
- Test: `Tests/CoveyKitTests/PersistedStateTests.swift`

**Interfaces:**
- Produces:

```swift
public struct IssueDraft: Codable, Equatable {
    public var title: String
    public var body: String
    public var assignMe: Bool
    public init(title: String = "", body: String = "", assignMe: Bool = false)
}
// PersistedState:
public var issueDrafts: [String: IssueDraft]?   // key: project root
public var inspectorSplit: Bool?
```

- [ ] **Step 1: Падающий тест** — в конец класса PersistedStateTests:

```swift
    func testIssueDraftsAndInspectorSplitRoundTrip() throws {
        var st = PersistedState()
        st.issueDrafts = ["/repo": IssueDraft(title: "t", body: "b", assignMe: true)]
        st.inspectorSplit = true
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.issueDrafts?["/repo"],
                       IssueDraft(title: "t", body: "b", assignMe: true))
        XCTAssertEqual(back.inspectorSplit, true)
    }
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter testIssueDraftsAndInspectorSplitRoundTrip 2>&1 | grep error | head -2`
Expected: `cannot find 'IssueDraft'`.

- [ ] **Step 3: Реализация** — в `PersistedState.swift` перед `PersistedState`:

```swift
/// The issue composer's per-project draft: survives closing the pane and
/// GUI restarts; cleared after a successful `gh issue create`.
public struct IssueDraft: Codable, Equatable {
    public var title: String
    public var body: String
    public var assignMe: Bool
    public init(title: String = "", body: String = "", assignMe: Bool = false) {
        self.title = title; self.body = body; self.assignMe = assignMe
    }
}
```

В `PersistedState`: поля `public var issueDrafts: [String: IssueDraft]?` и
`public var inspectorSplit: Bool?` после `splitAxes`; в init — параметры
`issueDrafts: [String: IssueDraft]? = nil, inspectorSplit: Bool? = nil`
(перед lastVersion) + присваивания.

- [ ] **Step 4: Прогон**

Run: `swift test --filter PersistedStateTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/CoveyKit/PersistedState.swift Tests/CoveyKitTests/PersistedStateTests.swift
git commit -m "feat(kit): IssueDraft + inspectorSplit in persisted state"
```

---

### Task 2: KeyRouter — inspector-зона + `space w`

**Files:**
- Modify: `Sources/covey/KeyRouter.swift`
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`

**Interfaces:**
- Produces: `KeyAction.inspectorTab(next: Bool)`, `.inspectorPaneSwap`,
  `.inspectorSplitToggle`, `.toggleSessionsPanel`, `.toggleInspectorPanel`,
  `.toggleFooterPanel`, `.toggleHeaderPanel`; `LeaderMenu.window`.

- [ ] **Step 1: Падающие тесты** — в конец KeyRouterTests:

```swift
    func testInspectorZoneChords() {
        let insp = ctx(focus: .inspector)
        XCTAssertEqual(KeyRouter.route(key("l", ctrl: true), context: insp),
                       .inspectorTab(next: true))
        XCTAssertEqual(KeyRouter.route(key("h", ctrl: true), context: insp),
                       .inspectorTab(next: false))
        XCTAssertEqual(KeyRouter.route(key("j", ctrl: true), context: insp),
                       .inspectorPaneSwap)
        XCTAssertEqual(KeyRouter.route(key("k", ctrl: true), context: insp),
                       .inspectorPaneSwap)
        XCTAssertEqual(KeyRouter.route(key("s"), context: insp), .inspectorSplitToggle)
        XCTAssertEqual(KeyRouter.route(key("s"), context: ctx(mode: .note, focus: .inspector)),
                       .inspectorSplitToggle)
        // Outside the zone the old meanings stay.
        XCTAssertEqual(KeyRouter.route(key("l", ctrl: true), context: ctx()),
                       .cycleFocus(forward: true))
        XCTAssertEqual(KeyRouter.route(key("s"), context: ctx()), .enterSelectMode)
    }

    func testWindowLeaderGroup() {
        XCTAssertEqual(KeyRouter.route(key("w"), context: ctx(mode: .leader(.root))),
                       .leaderDescend(.window))
        let w = ctx(mode: .leader(.window))
        XCTAssertEqual(KeyRouter.route(key("s"), context: w), .toggleSessionsPanel)
        XCTAssertEqual(KeyRouter.route(key("i"), context: w), .toggleInspectorPanel)
        XCTAssertEqual(KeyRouter.route(key("f"), context: w), .toggleFooterPanel)
        XCTAssertEqual(KeyRouter.route(key("h"), context: w), .toggleHeaderPanel)
    }
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter "testInspectorZoneChords|testWindowLeaderGroup" 2>&1 | grep error | head -3`
Expected: `no member 'inspectorTab'` / `'window'`.

- [ ] **Step 3: Реализация KeyRouter.swift**

- `LeaderMenu` → `case root, git, session, app, terminal, window`.
- `KeyAction` — добавить:

```swift
    case inspectorTab(next: Bool)
    case inspectorPaneSwap
    case inspectorSplitToggle
    case toggleSessionsPanel
    case toggleInspectorPanel
    case toggleFooterPanel
    case toggleHeaderPanel
```

- В `route`, ПОСЛЕ terminal-ветки и ПЕРЕД `guard context.vimMode`
  (инспектор-чорды работают и с мышиным фокусом? нет — зона vim-first;
  ставим ПОСЛЕ `guard context.vimMode else { return nil }` и ПЕРЕД
  `switch context.mode`):

```swift
        // Inspector zone: tab/pane chords override the global ⌃h/l/j/k,
        // `s` toggles tabs<->split (list navigation never uses s here).
        if context.focus == .inspector {
            if input.isControl {
                switch ch {
                case "l": return .inspectorTab(next: true)
                case "h": return .inspectorTab(next: false)
                case "j", "k": return .inspectorPaneSwap
                default: break
                }
            } else if ch == "s",
                      context.mode == .normal || context.mode == .note {
                return .inspectorSplitToggle
            }
        }
```

- В `routeLeader`:

```swift
        case (.root, "w"): return .leaderDescend(.window)
        case (.window, "s"): return .toggleSessionsPanel
        case (.window, "i"): return .toggleInspectorPanel
        case (.window, "f"): return .toggleFooterPanel
        case (.window, "h"): return .toggleHeaderPanel
```

ВНИМАНИЕ: leader-режим при фокусе inspector — inspector-ветка выше
не должна перехватить `s` в режиме `.leader`: условие
`mode == .normal || .note` это гарантирует.

- [ ] **Step 4: Временная заглушка в AppModel.apply** (Task 3 заменит):

```swift
        case .inspectorTab, .inspectorPaneSwap, .inspectorSplitToggle,
             .toggleSessionsPanel, .toggleInspectorPanel,
             .toggleFooterPanel, .toggleHeaderPanel:
            break   // wired in the next task
```

- [ ] **Step 5: Прогон**

Run: `swift test --filter KeyRouterTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 6: Commit (user)**

```bash
git add Sources/covey/KeyRouter.swift Sources/covey/AppModel.swift Tests/CoveyAppTests/KeyRouterTests.swift
git commit -m "feat(covey): inspector zone chords and space w window group (routes)"
```

---

### Task 3: AppModel — табы/сплит/драфты/window-тоглы, минус Modal.issue

**Files:**
- Modify: `Sources/covey/AppModel.swift`
- Modify: `Sources/covey/Views/Sheets.swift` (минус `Modal.id` кейс issue, минус IssueSheet)
- Modify: `Sources/covey/Views/ContentView.swift` (минус sheet-кейс)
- Test: `Tests/CoveyAppTests/AppModelChromeTests.swift`

**Interfaces:**
- Consumes: `IssueDraft`, `PersistedState.issueDrafts/inspectorSplit` (Task 1); KeyAction-кейсы (Task 2).
- Produces:

```swift
public enum InspectorTab: Equatable { case note, issue }
public private(set) var inspectorTab: InspectorTab   // = .note
public private(set) var inspectorSplit: Bool         // persisted
/// Transient: a pane sets it when its editor/field owns the keyboard.
public var inspectorEditing = false
/// Bumped by space g i; IssuePane focuses the title field on change.
public private(set) var issueFocusTick = 0
public func issueDraft(forRoot root: String) -> IssueDraft
public func setIssueDraft(_ draft: IssueDraft, forRoot root: String)
public func clearIssueDraft(forRoot root: String)
public func sessionRootOfSelected() -> String?   // sessionRoot(selectedSession)
```

- [ ] **Step 1: Падающие тесты** — в AppModelChromeTests ЗАМЕНИТЬ
  `testCreateIssueGuards` (модалки issue больше нет) и добавить новые:

```swift
    @MainActor
    func testCreateIssueOpensInspectorIssueTab() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "no session")

        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        model.apply(.createIssue)
        XCTAssertEqual(model.toast, "not a git repo")

        daemon.gitMonitor.onGitChanged?("agent", GitInfo(branch: "main", added: 0, removed: 0))
        _ = await eventually { model.sessions.first?.git != nil }
        let tickBefore = model.issueFocusTick
        model.apply(.createIssue)
        XCTAssertNil(model.modal)
        XCTAssertTrue(model.showInspector)
        XCTAssertEqual(model.inspectorTab, .issue)
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.issueFocusTick, tickBefore + 1)

        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testInspectorTabsSplitAndWindowToggles() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        XCTAssertEqual(model.inspectorTab, .note)
        model.apply(.inspectorTab(next: true))
        XCTAssertEqual(model.inspectorTab, .issue)
        model.apply(.inspectorTab(next: false))
        XCTAssertEqual(model.inspectorTab, .note)
        model.apply(.inspectorPaneSwap)
        XCTAssertEqual(model.inspectorTab, .issue, "pane swap flips the active pane")

        XCTAssertFalse(model.inspectorSplit)
        model.apply(.inspectorSplitToggle)
        XCTAssertTrue(model.inspectorSplit)

        let sessionsShown = model.showSessions
        model.apply(.toggleSessionsPanel)
        XCTAssertEqual(model.showSessions, !sessionsShown)
        let footerShown = model.showFooter
        model.apply(.toggleFooterPanel)
        XCTAssertEqual(model.showFooter, !footerShown)
        let headerShown = model.showHeader
        model.apply(.toggleHeaderPanel)
        XCTAssertEqual(model.showHeader, !headerShown)

        // Hiding the inspector while focused inside returns to sessions.
        model.setShowInspector(true)
        model.setFocus(.inspector)
        model.apply(.toggleInspectorPanel)
        XCTAssertFalse(model.showInspector)
        XCTAssertEqual(model.focus, .sessions)
    }

    @MainActor
    func testIssueDraftPerProjectRoot() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertEqual(model.issueDraft(forRoot: "/repo"), IssueDraft())
        model.setIssueDraft(IssueDraft(title: "t", body: "b", assignMe: true),
                            forRoot: "/repo")
        XCTAssertEqual(model.issueDraft(forRoot: "/repo").title, "t")
        model.clearIssueDraft(forRoot: "/repo")
        XCTAssertEqual(model.issueDraft(forRoot: "/repo"), IssueDraft())
    }
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter "testCreateIssueOpensInspectorIssueTab|testInspectorTabsSplitAndWindowToggles|testIssueDraftPerProjectRoot" 2>&1 | grep error | head -3`
Expected: `no member 'inspectorTab'` и т.п.

- [ ] **Step 3: Реализация AppModel**

Состояние (рядом с showInspector):

```swift
    public enum InspectorTab: Equatable { case note, issue }
    public private(set) var inspectorTab: InspectorTab = .note
    public private(set) var inspectorSplit = false
    /// Transient: a pane sets it while its editor/field owns the keyboard
    /// (drives the INSERT/NORMAL badge).
    public var inspectorEditing = false
    /// Bumped by space g i; IssuePane focuses the title field on change.
    public private(set) var issueFocusTick = 0
```

`start()`: `inspectorSplit = persisted.inspectorSplit ?? false`.
`persist()`: `persisted.inspectorSplit = inspectorSplit` (issueDrafts живёт
в persisted напрямую, как splitAxes — persist() их не перечисляет).

Хелперы (рядом с selectedSession):

```swift
    public func sessionRootOfSelected() -> String? {
        selectedSession().map(sessionRoot)
    }

    public func issueDraft(forRoot root: String) -> IssueDraft {
        persisted.issueDrafts?[root] ?? IssueDraft()
    }

    public func setIssueDraft(_ draft: IssueDraft, forRoot root: String) {
        var drafts = persisted.issueDrafts ?? [:]
        drafts[root] = draft
        persisted.issueDrafts = drafts
        persist()
    }

    public func clearIssueDraft(forRoot root: String) {
        persisted.issueDrafts?[root] = nil
        persist()
    }
```

`apply` — заглушку Task 2 заменить:

```swift
        case .inspectorTab(let next):
            _ = next   // two tabs: either direction flips
            inspectorTab = inspectorTab == .note ? .issue : .note
        case .inspectorPaneSwap:
            inspectorTab = inspectorTab == .note ? .issue : .note
        case .inspectorSplitToggle:
            inspectorSplit.toggle()
            persist()
        case .toggleSessionsPanel:
            inputMode = .normal
            setShowSessions(!showSessions)
        case .toggleInspectorPanel:
            inputMode = .normal
            if showInspector, focus == .inspector { setFocus(.sessions) }
            setShowInspector(!showInspector)
        case .toggleFooterPanel:
            inputMode = .normal
            setShowFooter(!showFooter)
        case .toggleHeaderPanel:
            inputMode = .normal
            setShowHeader(!showHeader)
```

`case .createIssue` — заменить тело:

```swift
        case .createIssue:
            inputMode = .normal
            guard let s = selectedSession() else { toast = "no session"; return }
            if s.git == nil { toast = "not a git repo"; return }
            if !showInspector { setShowInspector(true) }
            inspectorTab = .issue
            setFocus(.inspector)
            issueFocusTick += 1
```

`Modal` — удалить `case issue(String)`; `Sources/covey/Views/Sheets.swift`:
удалить `case .issue(...)` из `Modal.id` и ВЕСЬ `struct IssueSheet`;
`Sources/covey/Views/ContentView.swift`: удалить sheet-кейс `.issue`.

- [ ] **Step 4: Прогон**

Run: `swift test --filter "AppModelChromeTests|KeyRouterTests" 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures. Полный `swift test` может падать по видам — Task 4 чинит; если падают НЕ вьюхи — чинить сейчас.

- [ ] **Step 5: Commit (user, вместе с Task 4 если полный набор красный)**

```bash
git add Sources/covey/AppModel.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/ContentView.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): inspector tabs/split state, issue drafts, window toggles"
```

---

### Task 4: Views — InspectorView табы/сплит/бейдж, IssuePane, NotePane иконки

**Files:**
- Modify: `Sources/covey/Views/InspectorView.swift` (полная переработка)
- Create: `Sources/covey/Views/IssuePane.swift`
- Create: `Sources/covey/Views/KbdBadge.swift`
- Modify: `Sources/covey/Views/NotePane.swift`
- Modify: `Sources/covey/Views/StatusBar.swift` (kbd → общий KbdBadge)
- Modify: `Sources/covey/Views/WhichKeyView.swift`, `Sources/covey/Views/HelpOverlay.swift`
- Test: полный `swift test`

**Interfaces:**
- Consumes: всё из Task 3; `IssueService.create(dir:title:body:assignMe:web:)`,
  `collapseHome`, `ayuField(_:focused:)`, `sessionRoot(_:)`.

- [ ] **Step 1: KbdBadge** — создать `Sources/covey/Views/KbdBadge.swift`:

```swift
import SwiftUI

/// The footer's key badge (bright kbd chip + dim label), shared by the
/// status bar and the inspector's hint rows.
struct KbdBadge: View {
    let key: String
    let label: String
    let tk: Tokens

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tk.t2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tk.surf2, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tk.bd2))
            Text(label).font(.caption).foregroundStyle(tk.t4)
        }
    }
}
```

`StatusBar.swift`: `hintsRow` использует `KbdBadge(key:label:tk:)` вместо
локального `kbd(_:)` + Text; локальную `kbd` удалить.

- [ ] **Step 2: IssuePane** — создать `Sources/covey/Views/IssuePane.swift`
  (логика стадий/submit — перенос из удалённого IssueSheet):

```swift
import SwiftUI
import AppKit
import CoveyKit

/// GitHub-issue composer living in the inspector: per-project draft,
/// ⌘-chords with footer hints, async gh stages. `gh issue create --web`
/// pre-fills the browser form from the same fields.
struct IssuePane: View {
    @Bindable var model: AppModel

    enum Stage: Equatable {
        case editing, creating
        case done(String)
        case failed(String)
    }

    @State private var stage: Stage = .editing
    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var root: String? { model.sessionRootOfSelected() }
    private var dir: String? { model.sessions.first { $0.name == model.selected }?.dir }

    private var draft: IssueDraft {
        root.map { model.issueDraft(forRoot: $0) } ?? IssueDraft()
    }

    private func update(_ transform: (inout IssueDraft) -> Void) {
        guard let root else { return }
        var d = model.issueDraft(forRoot: root)
        transform(&d)
        model.setIssueDraft(d, forRoot: root)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if root == nil {
                Text("select a session in a git repo")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch stage {
                case .editing: editor
                case .creating:
                    Text("creating issue…").font(.headline)
                    Text("esc hide — gh keeps running")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                case .done(let url):
                    Label("issue created", systemImage: "checkmark")
                        .font(.headline).foregroundStyle(tk.ok)
                    Text(url).font(.caption.monospaced()).textSelection(.enabled)
                    Text("(copied to clipboard)")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button("New issue") { stage = .editing }
                    Spacer()
                case .failed(let err):
                    Label("issue not created", systemImage: "xmark")
                        .font(.headline).foregroundStyle(tk.err)
                    Text(err).font(.caption).foregroundStyle(tk.err)
                        .textSelection(.enabled)
                    Button("Back") { stage = .editing }
                    Spacer()
                }
            }
        }
        .padding(8)
        .onChange(of: model.issueFocusTick) { _, _ in
            stage = .editing
            titleFocused = true
        }
        .onChange(of: titleFocused) { _, _ in syncEditing() }
        .onChange(of: bodyFocused) { _, _ in syncEditing() }
    }

    private func syncEditing() {
        model.inspectorEditing = titleFocused || bodyFocused
    }

    private var editor: some View {
        Group {
            Text("in: \(collapseHome(root ?? ""))")
                .font(.caption.monospaced()).foregroundStyle(tk.t3).lineLimit(1)
            TextField("Title", text: Binding(
                get: { draft.title },
                set: { v in update { $0.title = v } }))
                .focused($titleFocused)
                .ayuField(tk, focused: titleFocused)
                .onSubmit { submit() }
            TextEditor(text: Binding(
                get: { draft.body },
                set: { v in update { $0.body = v } }))
                .focused($bodyFocused)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(tk.surf2, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(bodyFocused ? tk.accent.opacity(0.7) : tk.bd2))
                .tint(tk.accent)
                .onKeyPress(.tab) {
                    bodyFocused = false
                    titleFocused = true
                    return .handled
                }
            HStack(spacing: 8) {
                Image(systemName: draft.assignMe ? "checkmark.square.fill" : "square")
                    .foregroundStyle(draft.assignMe ? Color.accentColor : .secondary)
                Text("Assign to me").font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { update { $0.assignMe.toggle() } }
            HStack {
                Spacer()
                Button("Open in browser…") { submit(web: true) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Create") { submit() }
                    .buttonStyle(.glassProminent)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // ⌘M rides a hidden button: the visible checkbox is not a Button.
            Button("") { update { $0.assignMe.toggle() } }
                .keyboardShortcut("m", modifiers: .command)
                .hidden().frame(width: 0, height: 0)
            HStack(spacing: 10) {
                KbdBadge(key: "enter", label: "create", tk: tk)
                KbdBadge(key: "⌘ M", label: "assign", tk: tk)
                KbdBadge(key: "⌘ O", label: "browser", tk: tk)
            }
        }
    }

    private func submit(web: Bool = false) {
        guard let root, let dir else { return }
        let d = model.issueDraft(forRoot: root)
        let title = d.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        stage = .creating
        Task { @MainActor in
            switch await IssueService.create(dir: dir, title: title, body: d.body,
                                             assignMe: d.assignMe, web: web) {
            case .success(let url):
                if web {
                    stage = .editing   // draft stays; the browser owns it now
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                model.clearIssueDraft(forRoot: root)
                stage = .done(url)
                model.showToast("issue created — URL copied")
            case .failure(let err):
                stage = .failed(err)
            }
        }
    }
}
```

- [ ] **Step 3: InspectorView** — заменить целиком:

```swift
import SwiftUI

/// Right drawer: zone tabs Note/Issue, tabs or vertical split, nvim-style
/// INSERT/NORMAL badge in the bottom-right corner.
struct InspectorView: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            tabsHeader
            if model.inspectorSplit {
                NotePane(model: model)
                Divider()
                IssuePane(model: model)
            } else if model.inspectorTab == .note {
                NotePane(model: model)
            } else {
                IssuePane(model: model)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(model.inspectorEditing || model.noteState.editing ? "INSERT" : "NORMAL")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.inspectorEditing || model.noteState.editing
                                 ? tk.warn : tk.t4)
                .padding(6)
        }
    }

    private var tabsHeader: some View {
        HStack(spacing: 12) {
            tab("Note", .note)
            tab("Issue", .issue)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
    }

    private func tab(_ label: String, _ value: AppModel.InspectorTab) -> some View {
        let active = model.inspectorSplit || model.inspectorTab == value
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active && model.inspectorTab == value ? tk.accent : tk.t4)
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                model.selectInspectorTab(value)
            }
    }
}
```

Для клика по табу в AppModel добавить (рядом с фокус-хелперами):

```swift
    public func selectInspectorTab(_ tab: InspectorTab) { inspectorTab = tab }
```

(и `inspectorTab` остаётся `private(set)`).

ВНИМАНИЕ: NotePane при отсутствии noteTarget сам показывает подсказку —
проверить: старый плейсхолдер «Inspector» жил в InspectorView; теперь
NotePane должен переживать `noteTarget == nil`: в NotePane.body, если
`model.noteTarget == nil`, показать

```swift
            Text("t session note · T project note")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

вместо контента.

- [ ] **Step 4: NotePane** — иконки и заголовок в тело:

- header: `Text(model.noteTitle())` заменить мелкой строкой ВНУТРИ
  rendered/editor верхом:

```swift
            HStack(spacing: 6) {
                Text(model.noteTitle()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if counts.total > 0 {
                    Text("\(counts.done)/\(counts.total)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if model.noteState.clearArmed {
                    Text("y to clear").font(.caption).foregroundStyle(.red)
                }
                Button {
                    if model.noteState.editing { commitEdit() } else { startEdit() }
                } label: {
                    Image(systemName: model.noteState.editing
                          ? "square.and.arrow.down" : "pencil")
                }
                .buttonStyle(.borderless).font(.caption)
                .help(model.noteState.editing ? "Save" : "Edit")
            }
            .padding(8)
```

(это остаётся первым рядом VStack — фактически прежний header, но без
жирного заголовка и с иконками; `Divider()` под ним сохранить).

- [ ] **Step 5: WhichKey + Help**

WhichKeyView root — добавить строку:

```swift
            Row(key: "w", label: "window — sessions · inspector · footer · header", implemented: true),
```

новый кейс:

```swift
        case .window: return [
            Row(key: "s", label: "toggle session list", implemented: true),
            Row(key: "i", label: "toggle inspector", implemented: true),
            Row(key: "f", label: "toggle footer", implemented: true),
            Row(key: "h", label: "toggle header", implemented: true),
        ]
```

`title`: `case .window: return "space w — window"`.

HelpOverlay, leader-группа: `("w", "window: sessions · inspector · footer · header")`;
в view-группу добавить `("⌃h / ⌃l (inspector)", "note / issue tab")`,
`("s (inspector)", "tabs / split")`.

- [ ] **Step 6: Полный прогон**

Run: `swift build 2>&1 | grep -c error:; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 ошибок, 0 failures.

- [ ] **Step 7: Commit (user; если Task 3 не коммитился отдельно — включить его файлы)**

```bash
git add Sources/covey/Views/InspectorView.swift Sources/covey/Views/IssuePane.swift Sources/covey/Views/KbdBadge.swift Sources/covey/Views/NotePane.swift Sources/covey/Views/StatusBar.swift Sources/covey/Views/WhichKeyView.swift Sources/covey/Views/HelpOverlay.swift
git commit -m "feat(covey): inspector note/issue tabs, split, issue pane with drafts"
```

---

### Task 5: Смоук (user) + docs commit

Рестарт демона НЕ нужен.

- [ ] **Step 1: Смоук по спеке §8**

1. `space g i` — правая шторка, таб Issue активен, курсор в Title.
2. Заполнить поля, `⌘ M` — галка; уйти по зонам, вернуться — драфт жив;
   перезапуск GUI — драфт жив.
3. Enter в Title — creating → done, URL в клипборде, драфт очищен.
4. `⌘ O` — браузер с заполненными title/body/assignee; драфт остался.
   ⚠ если ⌘M перехватился системным Minimize — сказать, переедем на ⌘E.
5. `s` в инспекторе — сплит note+issue, `⌃j/⌃k` между панелями;
   `s` назад, `⌃h/⌃l` — табы.
6. Note: карандаш/дискета; INSERT/NORMAL в правом нижнем углу.
7. `space w s/i/f/h` — тоглы панелей; скрытие инспектора из его зоны
   возвращает фокус в список.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/plans/2026-07-06-covey-inspector-issue.md
git commit -m "docs: slice 25 implementation plan — inspector note/issue"
```
