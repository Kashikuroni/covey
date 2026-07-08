# Слайс 31 — детали issue: пин шапки, MD-рендер, типографика (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Шапка деталей issue закреплена (скроллится только описание), описание рендерится общим markdown-рендерером заметок, шрифты issue-вью +2pt через единые константы.

**Architecture:** Line-рендерер выносится из VimPreview в `MarkdownLineView` (общий с превью заметок); IssueDetailView перестраивается в «фикс-шапка + ScrollView(md)»; размеры собираются в `IssueFont`.

**Tech Stack:** Swift/SwiftUI. **Spec:** `/covey/docs/superpowers/specs/2026-07-08-covey-issue-detail-polish-design.md`
**Working tree:** `/Users/kashikuroni/projects/pets/covey-slice-28` (ветка slice-28). Baseline: 388/1/0.

## Global Constraints

- Код/комментарии — английский. **Git-коммиты делает пользователь.**
- Превью заметок пиксельно НЕ меняется (рендерер переносится 1:1).
- MD-тело живёт на размерах рендерера (общих с заметками) — его шрифты не трогать.
- IssueFont: title 15, body 13, meta 12, mono 15, monoSmall 12.
- Селекция текста описания опускается (спека §1); плейсхолдер «no description» остаётся.
- Новый .swift-файл ⇒ `xcodegen generate` в финале.

---

### Task 1: MarkdownLineView (общий рендерер)

**Files:** Create `Sources/covey/Views/MarkdownLine.swift`; Modify `Sources/covey/Views/VimEditor.swift:490-522` (render → MarkdownLineView).

- [ ] Step 1: новый файл — switch из VimEditor.swift:491-522 переносится 1:1:

```swift
import SwiftUI

/// Obsidian-style line renderer shared by the note preview and the issue
/// body: headings, checkboxes, bullets, plain text. One place — identical
/// markdown look everywhere.
struct MarkdownLineView: View {
    let line: NoteLine
    let tk: Tokens

    var body: some View {
        switch line {
        case .heading(let level, let textLine):
            Text(textLine)
                .font(.system(size: level == 1 ? 15 : 13,
                              weight: level == 1 ? .bold : .semibold))
                .padding(.top, 2)
        case .task(let done, let textLine):
            // Obsidian-style checkbox: crisp SF glyph, done fades + strikes.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(done ? AnyShapeStyle(tk.ok.opacity(0.85))
                                          : AnyShapeStyle(tk.t3))
                Text(textLine)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? AnyShapeStyle(.secondary)
                                          : AnyShapeStyle(.primary))
            }
            .font(.callout)
        case .bullet(let textLine):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(tk.t3)
                Text(textLine)
            }
            .font(.callout)
        case .text(let textLine):
            Text(textLine).font(.callout)
        case .blank:
            Text(" ").font(.caption2)
        }
    }
}
```

- [ ] Step 2: в VimEditor удалить приватный `render(_:)` (вместе с `@ViewBuilder`), вызов `render(line)` в VimPreview → `MarkdownLineView(line: line, tk: tk)`.
- [ ] Step 3: `swift build && swift test` — 388/1/0.
- [ ] Step 4: Commit-msg: `refactor(covey): shared MarkdownLineView for note preview and issue body`

### Task 2: IssueFont

**Files:** Create `Sources/covey/Views/IssueFonts.swift`.

- [ ] Step 1:

```swift
import Foundation

/// Single tuning point for the issue UI type scale (spec: +2pt toward the
/// agent pane's text; adjust here, not per-view).
enum IssueFont {
    static let title: CGFloat = 15
    static let body: CGFloat = 13
    static let meta: CGFloat = 12
    static let mono: CGFloat = 15
    static let monoSmall: CGFloat = 12
}
```

- [ ] Step 2: `swift build` чистый.
- [ ] Step 3: Commit-msg: `feat(covey): IssueFont type-scale constants`

### Task 3: IssueDetailView — пин шапки + MD

**Files:** Modify `Sources/covey/Views/IssueDetailView.swift` (полная перестройка).

- [ ] Step 1: новое тело (шапка фикс, Divider, ScrollView с parseNote→MarkdownLineView; шрифты на IssueFont; пустое body — плейсхолдер):

```swift
import SwiftUI

/// Read-only issue detail: pinned header (number, title, state, author,
/// date, labels) over a body-only scroll. The body renders through the
/// shared markdown line renderer; keys live in IssueBrowserPane.
struct IssueDetailView: View {
    let issue: GhIssue
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#\(issue.number)")
                    .font(.system(size: IssueFont.body, design: .monospaced))
                    .foregroundStyle(tk.t3)
                Text(issue.isOpen ? "OPEN" : "CLOSED")
                    .font(.system(size: IssueFont.meta, weight: .bold))
                    .foregroundStyle(issue.isOpen ? tk.ok : tk.t4)
                Spacer()
            }
            Text(issue.title)
                .font(.system(size: IssueFont.title, weight: .semibold))
                .foregroundStyle(tk.t1)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(issue.author)
                    .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t3)
                Text(issue.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
            }
            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels, id: \.name) { label in
                        Text(label.name)
                            .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(tk.surf2, in: Capsule())
                            .overlay(Capsule().strokeBorder(tk.bd2))
                    }
                }
            }
            Divider()
            if issue.body.isEmpty {
                Text("no description")
                    .font(.system(size: IssueFont.body)).foregroundStyle(tk.t4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(parseNote(issue.body).enumerated()),
                                id: \.offset) { _, line in
                            MarkdownLineView(line: line, tk: tk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
```

- [ ] Step 2: `swift build && swift test`.
- [ ] Step 3: Commit-msg: `feat(covey): pinned issue header, markdown body render`

### Task 4: шрифтовой свип + финал

**Files:** Modify `Views/IssueCardView.swift`, `Views/IssueEditView.swift`, `Views/IssueBrowserPane.swift`.

- [ ] Step 1: IssueCardView: mono(13)→mono(IssueFont.mono) для #N; титул `.caption`→`.system(size: IssueFont.body)`; превью/чипы/автор `.caption2`→`.system(size: IssueFont.meta)`; возраст/WIP mono(10)→mono(IssueFont.monoSmall) (helper mono(_:) уже есть — вызовы с константами).
- [ ] Step 2: IssueBrowserPane: header `in:`-строка `.caption.monospaced()`→`.system(size: IssueFont.meta, design: .monospaced)`; фильтр-индикатор `.caption2.monospaced()`→meta-mono; stale-note/empty `.caption2`/`.caption`→meta/body.
- [ ] Step 3: IssueEditView: подписи/чеклист `.caption`/`.caption2`→body/meta по смыслу (заголовок `edit #N` — meta-mono).
- [ ] Step 4: `swift build && swift test` (388/1/0) + `xcodegen generate` + xcodebuild Release SUCCEEDED.
- [ ] Step 5: Руками: длинный md-issue — шапка стоит, тело скроллится, md как в превью заметок; размеры ~ agent-текст; карточки/редактор укрупнились согласованно.
- [ ] Step 6: Commit-msg: `feat(covey): issue UI type scale +2pt via IssueFont`

## Self-Review (выполнен)
Спека §1→T1/T3, §2→T3, §3→T2/T4, §4→шаги верификации. Плейсхолдеров нет; IssueFont-имена сквозные.
