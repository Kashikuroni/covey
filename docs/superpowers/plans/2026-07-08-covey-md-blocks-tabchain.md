# Слайс 32 — MD-блоки, высота редактора, Tab к лейблам (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline).

**Goal:** parseNote/MarkdownLineView покрывают rule/quote/fence/code + инлайн bold/italic/mono; body-редактор issue — половина шторки; Tab/Shift-Tab включают лейблы в фокус-цикл.
**Spec:** `/covey/docs/superpowers/specs/2026-07-08-covey-md-blocks-tabchain-design.md`
**Working tree:** covey-slice-28 (slice-28). Baseline 388/1/0.

## Global Constraints
- Код английский; git-коммиты — пользователь; TDD для parseNote/inlineMD.
- Инвариант: `parseNote(N строк).count == N` — всегда.
- Фенс-маркер ``` → `.codeFence`; внутри фенса ЛЮБАЯ строка → `.code(raw)` (без trim).
- rule: строка только из ≥3 `-`/`*`/`_` (после trim, один вид символа).
- quote: `> ` или `>` префикс после trim; маркер срезается, один уровень.
- Инлайн: `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`, фейл → сырой текст.
- Высота body-редактора: `geo.size.height * 0.5`.
- Tab-цикл: title→body→label[0]→…→last→title; ⇧Tab: label[0]→body, body→title.

### Task 1: parseNote — rule/quote/fence/code (TDD)
Files: `Sources/covey/NoteModel.swift`, `Tests/CoveyAppTests/NoteModelTests.swift`.
- [ ] Тесты:

```swift
func testParseRuleQuoteFence() {
    XCTAssertEqual(parseNote("---"), [.rule])
    XCTAssertEqual(parseNote("***"), [.rule])
    XCTAssertEqual(parseNote("___"), [.rule])
    XCTAssertEqual(parseNote("--"), [.text("--")])          // < 3 chars
    XCTAssertEqual(parseNote("- - -"), [.bullet("- -")])     // mixed -> not a rule
    XCTAssertEqual(parseNote("> quoted"), [.quote("quoted")])
    XCTAssertEqual(parseNote(">bare"), [.quote("bare")])
    let fenced = parseNote("```swift\nlet x = 1\n\n```")
    XCTAssertEqual(fenced, [.codeFence, .code("let x = 1"), .code(""), .codeFence])
}

func testParseNoteLineCountInvariant() {
    let buf = "# h\n```\ncode\n---\n> q\n```\n---\n> q\ntext"
    XCTAssertEqual(parseNote(buf).count, buf.components(separatedBy: "\n").count)
    // Inside the fence nothing else is recognized.
    XCTAssertEqual(parseNote(buf)[3], .code("---"))
}
```

- [ ] RED → реализация: `NoteLine` += `.rule, .quote(String), .codeFence, .code(String)`; `parseNote` — цикл с `inFence`; фенс-маркер: trimmed.hasPrefix("```"). rule-детект: `trimmed.count >= 3 && Set(trimmed).count == 1 && "-*_".contains(trimmed.first!)`. quote: hasPrefix(">") → срез `>` + один пробел. Порядок проверок вне фенса: task → blank → heading → rule → quote → bullet → text.
  ВНИМАНИЕ: `- - -` — parseTask? нет (не `- [`); bullet(`- `) сработает раньше rule? Порядок: rule проверять ДО bullet (иначе `---`… `-` не bullet; `- - -` → bullet по спеку-тесту). `---` не имеет `- ` префикса — конфликтов нет; тест `- - -`→bullet("- -") закрепляет порядок bullet-после-rule.
- [ ] GREEN + `swift test --filter NoteModelTests`.
- Commit-msg: `feat(covey): markdown rules, quotes, code fences in parseNote`

### Task 2: MarkdownLineView — новые кейсы + inlineMD (TDD для inlineMD)
Files: `Sources/covey/Views/MarkdownLine.swift`, `Tests/CoveyAppTests/IssueModelsTests.swift` (или NoteModelTests — рядом с parseNote).
- [ ] Тест inlineMD:

```swift
func testInlineMD() {
    let bold = inlineMD("a **b** c")
    XCTAssertTrue(bold.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    let code = inlineMD("x `y` z")
    XCTAssertTrue(code.runs.contains {
        $0.inlinePresentationIntent?.contains(.code) == true })
    XCTAssertEqual(String(inlineMD("no markup").characters), "no markup")
}
```

- [ ] Реализация в MarkdownLine.swift:

```swift
/// Inline markdown (bold/italic/code/links) for one line; falls back to
/// the raw string when parsing fails.
func inlineMD(_ s: String) -> AttributedString {
    (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}
```

  В MarkdownLineView: `Text(textLine)` → `Text(inlineMD(textLine))` для heading/task/bullet/text; новые кейсы:

```swift
case .rule:
    Rectangle().fill(tk.bd2).frame(height: 1)
        .frame(maxWidth: .infinity).padding(.vertical, 4)
case .quote(let textLine):
    HStack(alignment: .top, spacing: 7) {
        Rectangle().fill(tk.t4).frame(width: 2)
        Text(inlineMD(textLine)).foregroundStyle(tk.t3)
    }
    .font(.callout)
case .codeFence:
    Spacer().frame(height: 2)
case .code(let raw):
    Text(raw)
        .font(.system(size: 13, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(tk.surf2)
```

- [ ] GREEN + build.
- Commit-msg: `feat(covey): inline md styles and block rendering in MarkdownLineView`

### Task 3: высота редактора
Files: `Sources/covey/Views/IssueEditView.swift`.
- [ ] body обернуть в `GeometryReader { geo in VStack {...} }`; VimEditor `.frame(height: 120)` → `.frame(height: max(120, geo.size.height * 0.5))`.
- Commit-msg: `feat(covey): issue body editor takes half the drawer height`

### Task 4: Tab-цикл
Files: `Sources/covey/Views/IssueEditView.swift`.
- [ ] `@State private var editorFocusTick = 0`; VimEditor вызов += `focusTick: editorFocusTick`.
- [ ] `onSwitchField: { forward in ... }`: forward && есть лейблы → `focusedLabel = первый`; иначе `titleFocused = true`.
- [ ] `handleLabelKey`: `.tab` (без shift) → следующий; с последнего → `titleFocused = true; focusedLabel = nil`; `.tab + shift` → предыдущий; с первого → `editorFocusTick += 1; focusedLabel = nil`. KeyPress: tab = `press.key == .tab`, shift = `press.modifiers.contains(.shift)`.
- Commit-msg: `fix(covey): Tab/Shift-Tab cycle reaches the label checklist`

### Task 5: финал
- [ ] `swift build && swift test` (390+ / 1 / 0); `xcodegen generate`; xcodebuild Release SUCCEEDED.
- [ ] Руками: **bold**/`mono`/---/цитаты/фенсы в описании issue и превью заметки; редактор в полвысоты; Tab-цикл по кругу, ⇧Tab обратно; space-тогл на лейбле после Tab-прихода.

## Self-Review (выполнен)
Спека §1→T1/T2 (инвариант — тестом), §2→T3, §3→T4, §4→T1/T2 тесты. Порядок rule-до-bullet закреплён тестом `- - -`.
