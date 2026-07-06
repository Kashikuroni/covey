# Слайс 26 — vim-редактор с MD-preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue body — vim-редактор: NORMAL/INSERT/VISUAL по сырцу, PREVIEW с markdown-рендером и скроллом, счётчики движений, номера строк; зона issue всегда в фокусе, ⌃-чорды пробиваются сквозь поля.

**Architecture:** Чистая машина `VimEngine` (chars/cursor/mode/pending/count; клипборд через эффекты) + `@Observable VimEditorModel`, которым делятся NSTextView-обёртка (normal/insert/visual) и SwiftUI-preview (рендер parseNote + номера строк). Зонные чорды выведены из-под NSTextView-гарда монитора.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI + AppKit (NSTextView, NSRulerView), XCTest.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-07-06-covey-vim-editor-design.md`.
- Весь код и коммиты на английском; `swift test` перед коммитом — 0 failures.
- Git-коммиты выполняет пользователь.
- Счётчики только для движений; без регистров/undo-в-NORMAL/V-line/поиска.
- SourceKit-фантомам не верить.

---

### Task 1: VimEngine — каркас, движения, INSERT-входы, счётчики

**Files:**
- Create: `Sources/covey/VimEngine.swift`
- Test: `Tests/CoveyAppTests/VimEngineTests.swift` (новый)

**Interfaces (Produces):**

```swift
enum VimInput: Equatable { case char(Character), escape, tab, shiftTab }
enum VimEffect: Equatable {
    case none
    case setPasteboard(String)
    case switchField(forward: Bool)
    case scrollCenter
}
struct VimEngine {
    enum Mode: Equatable { case normal, insert, visual(anchor: Int), preview }
    private(set) var cursor: Int
    private(set) var mode: Mode
    var text: String { get }
    init(text: String = "")
    mutating func syncFromView(text: String, cursor: Int)
    mutating func handle(_ input: VimInput, pasteboard: () -> String? = { nil }) -> VimEffect
    func lineOfCursor() -> Int        // 0-based, for the preview scroll
}
```

- [ ] **Step 1: Тесты движений/INSERT/счётчиков** — создать
  `Tests/CoveyAppTests/VimEngineTests.swift`:

```swift
import XCTest
@testable import covey

final class VimEngineTests: XCTestCase {
    private func engine(_ text: String, cursor: Int = 0) -> VimEngine {
        var e = VimEngine(text: text)
        e.syncFromView(text: text, cursor: cursor)
        return e
    }
    private func feed(_ e: inout VimEngine, _ keys: String) {
        for c in keys { _ = e.handle(.char(c)) }
    }

    func testHjklAndClamp() {
        var e = engine("abc\ndef", cursor: 0)
        feed(&e, "l"); XCTAssertEqual(e.cursor, 1)
        feed(&e, "h"); XCTAssertEqual(e.cursor, 0)
        feed(&e, "h"); XCTAssertEqual(e.cursor, 0, "h clamps at line start")
        feed(&e, "j"); XCTAssertEqual(e.cursor, 4, "j keeps column 0")
        feed(&e, "lll"); XCTAssertEqual(e.cursor, 6, "l clamps on the last char")
        feed(&e, "k"); XCTAssertEqual(e.cursor, 2, "k clamps the column")
    }

    func testWordMotions() {
        var e = engine("foo bar  baz")
        feed(&e, "w"); XCTAssertEqual(e.cursor, 4)
        feed(&e, "w"); XCTAssertEqual(e.cursor, 9)
        feed(&e, "b"); XCTAssertEqual(e.cursor, 4)
        feed(&e, "b"); XCTAssertEqual(e.cursor, 0)
        feed(&e, "b"); XCTAssertEqual(e.cursor, 0, "b clamps at 0")
    }

    func testLineMotionsAndGg() {
        var e = engine("one\ntwo\nthree", cursor: 5)
        feed(&e, "0"); XCTAssertEqual(e.cursor, 4)
        feed(&e, "$"); XCTAssertEqual(e.cursor, 6, "$ sits ON the last char")
        feed(&e, "G"); XCTAssertEqual(e.cursor, 8, "G -> first col of last line")
        feed(&e, "gg"); XCTAssertEqual(e.cursor, 0)
    }

    func testCounts() {
        var e = engine("a\nb\nc\nd\ne")
        feed(&e, "3j"); XCTAssertEqual(e.cursor, 6, "3j moves three lines")
        feed(&e, "2k"); XCTAssertEqual(e.cursor, 2)
        feed(&e, "9j"); XCTAssertEqual(e.cursor, 8, "count clamps at the end")
        feed(&e, "2G"); XCTAssertEqual(e.cursor, 2, "<N>G jumps to line N")
        var w = engine("aa bb cc dd")
        feed(&w, "2w"); XCTAssertEqual(w.cursor, 6)
    }

    func testInsertEntries() {
        var e = engine("ab\ncd", cursor: 1)
        feed(&e, "i"); XCTAssertEqual(e.mode, .insert); XCTAssertEqual(e.cursor, 1)
        _ = e.handle(.escape)
        XCTAssertEqual(e.mode, .normal)
        XCTAssertEqual(e.cursor, 0, "esc steps back like vim")
        feed(&e, "a"); XCTAssertEqual(e.cursor, 1); _ = e.handle(.escape)
        feed(&e, "A"); XCTAssertEqual(e.cursor, 2, "A -> line end"); _ = e.handle(.escape)
        feed(&e, "I"); XCTAssertEqual(e.cursor, 0); _ = e.handle(.escape)
        feed(&e, "o")
        XCTAssertEqual(e.text, "ab\n\ncd"); XCTAssertEqual(e.cursor, 3)
        _ = e.handle(.escape)
        feed(&e, "O")
        XCTAssertEqual(e.text, "ab\n\n\ncd"); XCTAssertEqual(e.cursor, 3)
    }

    func testTabSwitchesFieldOnlyFromNormal() {
        var e = engine("x")
        XCTAssertEqual(e.handle(.tab), .switchField(forward: true))
        XCTAssertEqual(e.handle(.shiftTab), .switchField(forward: false))
        feed(&e, "i")
        XCTAssertEqual(e.handle(.tab), .none, "insert keeps tab as typing")
    }
}
```

- [ ] **Step 2: Прогнать — падает** (`cannot find 'VimEngine'`).

Run: `swift test --filter VimEngineTests 2>&1 | grep error | head -2`

- [ ] **Step 3: Реализация каркаса** — создать `Sources/covey/VimEngine.swift`:

```swift
import Foundation

/// Keys the vim editor understands beyond printable characters.
enum VimInput: Equatable { case char(Character), escape, tab, shiftTab }

/// Side effects the view applies (the engine itself stays pure).
enum VimEffect: Equatable {
    case none
    case setPasteboard(String)
    case switchField(forward: Bool)
    case scrollCenter
}

/// Pure vim-lite machine over a plain text buffer. INSERT typing happens
/// natively in the NSTextView and is synced back via `syncFromView`; every
/// other mode feeds keys here.
struct VimEngine {
    enum Mode: Equatable { case normal, insert, visual(anchor: Int), preview }

    private(set) var chars: [Character]
    private(set) var cursor: Int = 0
    private(set) var mode: Mode = .normal
    private(set) var pending: Character?   // d / c / y awaiting a motion
    private(set) var pendingG = false      // g prefix (gg / gp)
    private(set) var count: Int?           // motion count (5j, 12G)

    var text: String { String(chars) }

    init(text: String = "") { chars = Array(text) }

    mutating func syncFromView(text: String, cursor: Int) {
        chars = Array(text)
        self.cursor = max(0, min(cursor, chars.count))
    }

    func lineOfCursor() -> Int {
        var line = 0
        for k in 0..<min(cursor, chars.count) where chars[k] == "\n" { line += 1 }
        return line
    }

    // MARK: - line helpers

    private func lineStart(_ i: Int) -> Int {
        var j = min(i, chars.count)
        while j > 0 && chars[j - 1] != "\n" { j -= 1 }
        return j
    }

    private func lineEnd(_ i: Int) -> Int {   // offset of the \n (or count)
        var j = min(max(i, 0), chars.count)
        while j < chars.count && chars[j] != "\n" { j += 1 }
        return j
    }

    private func lineStarts() -> [Int] {
        var starts = [0]
        for (k, c) in chars.enumerated() where c == "\n" { starts.append(k + 1) }
        return starts
    }

    /// Normal-mode cursor sits ON a character (line start when empty).
    private mutating func clampToLine() {
        let s = lineStart(cursor), e = lineEnd(cursor)
        if cursor >= e { cursor = max(s, e - 1) }
        if cursor < s { cursor = s }
    }

    private mutating func resetPrefixes() {
        pending = nil; pendingG = false; count = nil
    }

    // MARK: - input

    mutating func handle(_ input: VimInput,
                         pasteboard: () -> String? = { nil }) -> VimEffect {
        switch mode {
        case .insert:
            if input == .escape {
                mode = .normal
                cursor = max(lineStart(cursor), cursor - 1)
                clampToLine()
            }
            return .none
        case .preview:
            return handlePreview(input)
        case .normal, .visual:
            return handleNormalVisual(input, pasteboard: pasteboard)
        }
    }

    private mutating func handleNormalVisual(
        _ input: VimInput, pasteboard: () -> String?
    ) -> VimEffect {
        switch input {
        case .escape:
            mode = .normal
            resetPrefixes()
            return .none
        case .tab, .shiftTab:
            guard mode == .normal, pending == nil else { resetPrefixes(); return .none }
            return .switchField(forward: input == .tab)
        case .char(let c):
            return handleChar(c, pasteboard: pasteboard)
        }
    }

    private mutating func handleChar(
        _ c: Character, pasteboard: () -> String?
    ) -> VimEffect {
        if let d = c.wholeNumberValue, c.isNumber,
           (1...9).contains(d) || (d == 0 && count != nil) {
            count = (count ?? 0) * 10 + d
            return .none
        }
        if pendingG {
            pendingG = false
            switch c {
            case "g":
                let target = (count ?? 1) - 1
                return finishMotion(.linewise(toLine: target))
            case "p":
                if mode == .normal, pending == nil { mode = .preview }
                resetPrefixes()
                return .none
            default:
                resetPrefixes()
                return .none
            }
        }
        if c == "g" { pendingG = true; return .none }

        if let motion = motionKind(c) { return finishMotion(motion) }
        return handleEdit(c, pasteboard: pasteboard)   // Task 2
    }

    // MARK: - motions

    private enum MotionKind {
        case charwise(to: Int, inclusive: Bool)
        case linewise(toLine: Int)
    }

    private func motionKind(_ c: Character) -> MotionKind? {
        let n = max(count ?? 1, 1)
        let starts = lineStarts()
        let line = lineOfCursor()
        switch c {
        case "h": return .charwise(to: max(lineStart(cursor), cursor - n), inclusive: false)
        case "l":
            let e = lineEnd(cursor)
            return .charwise(to: min(cursor + n, e), inclusive: false)
        case "0": return .charwise(to: lineStart(cursor), inclusive: false)
        case "$": return .charwise(to: max(lineStart(cursor), lineEnd(cursor) - 1), inclusive: true)
        case "w": return .charwise(to: wordForward(from: cursor, times: n), inclusive: false)
        case "b": return .charwise(to: wordBack(from: cursor, times: n), inclusive: false)
        case "j": return .linewise(toLine: min(line + n, starts.count - 1))
        case "k": return .linewise(toLine: max(line - n, 0))
        case "G":
            return .linewise(toLine: count.map { min($0 - 1, starts.count - 1) }
                                   ?? starts.count - 1)
        default: return nil
        }
    }

    private mutating func finishMotion(_ motion: MotionKind) -> VimEffect {
        defer { count = nil }
        if pending != nil { return applyOperator(to: motion) }   // Task 2
        switch motion {
        case .charwise(let to, _):
            cursor = to
            if mode == .normal { clampToLine() }
        case .linewise(let toLine):
            moveCursor(toLine: toLine)
        }
        return .none
    }

    /// Row jump keeping the column clamped into the target line.
    private mutating func moveCursor(toLine target: Int) {
        let starts = lineStarts()
        let line = min(max(target, 0), starts.count - 1)
        let col = cursor - lineStart(cursor)
        let s = starts[line]
        let e = lineEnd(s)
        let maxCol = mode == .insert ? e - s : max(0, e - s - 1)
        cursor = s + min(col, max(0, maxCol))
        if chars.isEmpty { cursor = 0 }
    }

    private func wordForward(from: Int, times: Int) -> Int {
        var i = from
        for _ in 0..<times {
            while i < chars.count && !chars[i].isWhitespace { i += 1 }
            while i < chars.count && chars[i].isWhitespace { i += 1 }
        }
        return min(i, max(0, chars.count - 1))
    }

    private func wordBack(from: Int, times: Int) -> Int {
        var i = from
        for _ in 0..<times {
            while i > 0 && chars[i - 1].isWhitespace { i -= 1 }
            while i > 0 && !chars[i - 1].isWhitespace { i -= 1 }
        }
        return max(i, 0)
    }

    // MARK: - insert entries (o/O create lines; the rest position the caret)

    private mutating func enterInsert(_ c: Character) -> Bool {
        switch c {
        case "i": mode = .insert
        case "a":
            let e = lineEnd(cursor)
            cursor = min(cursor + 1, e)
            mode = .insert
        case "I": cursor = lineStart(cursor); mode = .insert
        case "A": cursor = lineEnd(cursor); mode = .insert
        case "o":
            let e = lineEnd(cursor)
            chars.insert("\n", at: e)
            cursor = e + 1
            mode = .insert
        case "O":
            let s = lineStart(cursor)
            chars.insert("\n", at: s)
            cursor = s
            mode = .insert
        default: return false
        }
        return true
    }

    // MARK: - edits (Task 2 fills this in)

    private mutating func handleEdit(
        _ c: Character, pasteboard: () -> String?
    ) -> VimEffect {
        if enterInsert(c) { resetPrefixes(); return .none }
        resetPrefixes()
        return .none
    }

    private mutating func applyOperator(to motion: MotionKind) -> VimEffect {
        pending = nil   // Task 2 replaces with the real implementation
        return .none
    }

    // MARK: - preview (Task 3 fills this in)

    private mutating func handlePreview(_ input: VimInput) -> VimEffect {
        if input == .escape { mode = .normal; resetPrefixes() }
        return .none
    }
}
```

- [ ] **Step 4: Прогон**

Run: `swift test --filter VimEngineTests 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/VimEngine.swift Tests/CoveyAppTests/VimEngineTests.swift
git commit -m "feat(covey): VimEngine core - motions, counts, insert entries"
```

---

### Task 2: VimEngine — правки, операторы, VISUAL, p/P

**Files:**
- Modify: `Sources/covey/VimEngine.swift` (handleEdit/applyOperator)
- Test: `Tests/CoveyAppTests/VimEngineTests.swift`

- [ ] **Step 1: Тесты** — добавить в VimEngineTests (pasteboard эмулируется
  замыканием; для проверки yank ловим эффект):

```swift
    private func feedFx(_ e: inout VimEngine, _ keys: String,
                        clip: String? = nil) -> [VimEffect] {
        keys.map { e.handle(.char($0), pasteboard: { clip }) }
    }

    func testXAndDd() {
        var e = engine("abc\ndef", cursor: 1)
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "ac\ndef")
        let fx = feedFx(&e, "dd")
        XCTAssertEqual(e.text, "def")
        XCTAssertTrue(fx.contains(.setPasteboard("ac\n")), "dd yanks linewise")
        _ = feedFx(&e, "dd")
        XCTAssertEqual(e.text, "", "dd of the only line leaves empty text")
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "", "x on empty is a no-op")
    }

    func testYyAndPasteLinewise() {
        var e = engine("one\ntwo", cursor: 0)
        let fx = feedFx(&e, "yy")
        XCTAssertTrue(fx.contains(.setPasteboard("one\n")))
        XCTAssertEqual(e.text, "one\ntwo", "yank does not edit")
        _ = feedFx(&e, "p", clip: "one\n")
        XCTAssertEqual(e.text, "one\none\ntwo", "linewise p pastes below")
        XCTAssertEqual(e.cursor, 4)
        var f = engine("ab", cursor: 0)
        _ = feedFx(&f, "p", clip: "XY")
        XCTAssertEqual(f.text, "aXYb", "charwise p pastes after the cursor")
        _ = feedFx(&f, "P", clip: "Z")
        XCTAssertEqual(f.text.contains("Z"), true)
    }

    func testOperatorWithMotions() {
        var e = engine("foo bar baz", cursor: 0)
        _ = feedFx(&e, "dw")
        XCTAssertEqual(e.text, "bar baz")
        _ = feedFx(&e, "d$")
        XCTAssertEqual(e.text, "", "d$ deletes through the last char")
        var f = engine("one\ntwo\nthree", cursor: 0)
        _ = feedFx(&f, "dj")
        XCTAssertEqual(f.text, "three", "dj is linewise over two lines")
        var g = engine("foo bar", cursor: 0)
        _ = feedFx(&g, "cw")
        XCTAssertEqual(g.text, "bar")
        XCTAssertEqual(g.mode, .insert, "c enters insert after the cut")
        var y = engine("foo bar", cursor: 0)
        let fx = feedFx(&y, "yw")
        XCTAssertTrue(fx.contains(.setPasteboard("foo ")))
        XCTAssertEqual(y.text, "foo bar")
    }

    func testCcClearsLine() {
        var e = engine("one\ntwo", cursor: 1)
        _ = feedFx(&e, "cc")
        XCTAssertEqual(e.text, "\ntwo")
        XCTAssertEqual(e.mode, .insert)
    }

    func testVisual() {
        var e = engine("abcdef", cursor: 1)
        _ = feedFx(&e, "v")
        XCTAssertEqual(e.mode, .visual(anchor: 1))
        _ = feedFx(&e, "ll")
        let fx = feedFx(&e, "y")
        XCTAssertTrue(fx.contains(.setPasteboard("bcd")), "visual y is inclusive")
        XCTAssertEqual(e.mode, .normal)
        _ = feedFx(&e, "v")
        _ = feedFx(&e, "l")
        _ = feedFx(&e, "d")
        XCTAssertEqual(e.text, "adef")
        var c = engine("abc", cursor: 0)
        _ = feedFx(&c, "vlc")
        XCTAssertEqual(c.text, "c")
        XCTAssertEqual(c.mode, .insert)
    }

    func testPendingResetOnInvalidMotion() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "dq")
        XCTAssertEqual(e.text, "abc", "invalid motion cancels the operator")
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "bc", "engine is usable right after")
    }
```

- [ ] **Step 2: Прогнать — падают** (тексты не меняются).

- [ ] **Step 3: Реализация** — заменить заглушки `handleEdit`/`applyOperator`:

```swift
    private mutating func handleEdit(
        _ c: Character, pasteboard: () -> String?
    ) -> VimEffect {
        // Visual-mode operators act on the selection immediately.
        if case .visual(let anchor) = mode, "dxyc".contains(c) {
            return applyVisual(c, anchor: anchor)
        }
        if enterInsert(c) { resetPrefixes(); return .none }
        switch c {
        case "v":
            mode = .visual(anchor: cursor)
            resetPrefixes()
            return .none
        case "x":
            defer { resetPrefixes() }
            let e = lineEnd(cursor)
            guard cursor < e else { return .none }
            chars.remove(at: cursor)
            clampToLine()
            return .none
        case "d", "c", "y":
            if pending == c {   // dd / cc / yy — linewise on the current line
                pending = nil
                return applyLinewise(c)
            }
            pending = c
            return .none
        case "p", "P":
            defer { resetPrefixes() }
            return paste(before: c == "P", pasteboard: pasteboard)
        default:
            resetPrefixes()
            return .none
        }
    }

    /// dd / yy / cc.
    private mutating func applyLinewise(_ op: Character) -> VimEffect {
        let s = lineStart(cursor)
        var e = lineEnd(cursor)
        let line = String(chars[s..<e])
        if op == "y" {
            cursor = s
            return .setPasteboard(line + "\n")
        }
        if op == "c" {   // clear the line's content, keep the newline
            chars.removeSubrange(s..<e)
            cursor = s
            mode = .insert
            return .setPasteboard(line + "\n")
        }
        if e < chars.count { e += 1 }          // take the trailing newline
        else if s > 0 { chars.remove(at: s - 1) } // last line: eat the \n before
        chars.removeSubrange(s..<min(e, chars.count))
        cursor = min(s, max(0, chars.count - 1))
        if chars.isEmpty { cursor = 0 }
        clampToLine()
        return .setPasteboard(line + "\n")
    }

    private mutating func applyOperator(to motion: MotionKind) -> VimEffect {
        guard let op = pending else { return .none }
        pending = nil
        switch motion {
        case .charwise(let to, let inclusive):
            var lo = min(cursor, to)
            var hi = max(cursor, to)
            if inclusive { hi = min(hi + 1, chars.count) }
            if lo == hi { return .none }
            hi = min(hi, chars.count)
            lo = max(lo, 0)
            let cut = String(chars[lo..<hi])
            if op == "y" {
                cursor = lo
                return .setPasteboard(cut)
            }
            chars.removeSubrange(lo..<hi)
            cursor = lo
            if op == "c" { mode = .insert } else { clampToLine() }
            return .setPasteboard(cut)
        case .linewise(let toLine):
            let starts = lineStarts()
            let cur = lineOfCursor()
            let a = min(cur, min(max(toLine, 0), starts.count - 1))
            let b = max(cur, min(max(toLine, 0), starts.count - 1))
            let s = starts[a]
            var e = lineEnd(starts[b])
            let cut = String(chars[s..<e]) + "\n"
            if op == "y" {
                cursor = s
                return .setPasteboard(cut)
            }
            if e < chars.count { e += 1 }
            else if s > 0 { chars.remove(at: s - 1) }
            chars.removeSubrange(s..<min(e, chars.count))
            cursor = min(s, max(0, chars.count - 1))
            if chars.isEmpty { cursor = 0 }
            if op == "c" {
                chars.insert("\n", at: min(cursor, chars.count))
                mode = .insert
            } else {
                clampToLine()
            }
            return .setPasteboard(cut)
        }
    }

    private mutating func applyVisual(_ op: Character, anchor: Int) -> VimEffect {
        let lo = min(anchor, cursor)
        let hi = min(max(anchor, cursor) + 1, chars.count)   // inclusive
        let cut = String(chars[lo..<hi])
        mode = .normal
        resetPrefixes()
        if op == "y" {
            cursor = lo
            clampToLine()
            return .setPasteboard(cut)
        }
        chars.removeSubrange(lo..<hi)
        cursor = lo
        if op == "c" { mode = .insert } else { clampToLine() }
        return .setPasteboard(cut)
    }

    private mutating func paste(before: Bool, pasteboard: () -> String?) -> VimEffect {
        guard let clip = pasteboard(), !clip.isEmpty else { return .none }
        if clip.hasSuffix("\n") {   // linewise
            let body = Array(clip)
            let at = before ? lineStart(cursor)
                            : min(lineEnd(cursor) + 1, chars.count)
            let insertAt = min(at, chars.count)
            if insertAt == chars.count && !chars.isEmpty && chars.last != "\n" {
                chars.append("\n")
                chars.insert(contentsOf: body.dropLast(), at: chars.count)
            } else {
                chars.insert(contentsOf: body, at: insertAt)
                if chars.last == "\n" { chars.removeLast() }
            }
            cursor = min(insertAt, max(0, chars.count - 1))
            clampToLine()
        } else {                    // charwise: after (p) / at (P) the cursor
            let at = before ? cursor
                            : min(cursor + 1, max(lineEnd(cursor), cursor))
            let insertAt = min(at, chars.count)
            chars.insert(contentsOf: Array(clip), at: insertAt)
            cursor = insertAt + clip.count - 1
            clampToLine()
        }
        return .none
    }
```

ВНИМАНИЕ: linewise-paste на последней строке без завершающего \n —
код выше добавляет/срезает \n так, чтобы текст не заканчивался лишней
пустой строкой; поведение пинится testYyAndPasteLinewise. Если тест
требует иной формы — правь реализацию, НЕ тест.

Также в `finishMotion` (Task 1) первая ветка уже зовёт
`applyOperator(to:)` — после этого шага она работает по-настоящему.

- [ ] **Step 4: Прогон** — `swift test --filter VimEngineTests` → 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/VimEngine.swift Tests/CoveyAppTests/VimEngineTests.swift
git commit -m "feat(covey): VimEngine edits - operators, visual, paste"
```

---

### Task 3: VimEngine — PREVIEW

**Files:**
- Modify: `Sources/covey/VimEngine.swift` (handlePreview + gp уже входит)
- Test: `Tests/CoveyAppTests/VimEngineTests.swift`

- [ ] **Step 1: Тесты**:

```swift
    func testPreviewEnterExitAndScroll() {
        var e = engine("l0\nl1\nl2\nl3\nl4", cursor: 0)
        _ = feedFx(&e, "gp")
        XCTAssertEqual(e.mode, .preview)
        _ = feedFx(&e, "j")
        XCTAssertEqual(e.lineOfCursor(), 1)
        _ = feedFx(&e, "3j")
        XCTAssertEqual(e.lineOfCursor(), 4)
        _ = feedFx(&e, "gg")
        XCTAssertEqual(e.lineOfCursor(), 0)
        _ = feedFx(&e, "G")
        XCTAssertEqual(e.lineOfCursor(), 4)
        _ = feedFx(&e, "2G")
        XCTAssertEqual(e.lineOfCursor(), 1)
        let fx = feedFx(&e, "zz")
        XCTAssertTrue(fx.contains(.scrollCenter))
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "l0\nl1\nl2\nl3\nl4", "preview never edits")
        _ = e.handle(.escape)
        XCTAssertEqual(e.mode, .normal)
    }
```

- [ ] **Step 2: Прогнать — падает** (mode не preview / движения нет).

- [ ] **Step 3: Реализация** — заменить `handlePreview`:

```swift
    private mutating func handlePreview(_ input: VimInput) -> VimEffect {
        switch input {
        case .escape:
            mode = .normal
            resetPrefixes()
            return .none
        case .tab, .shiftTab:
            return .none
        case .char(let c):
            if let d = c.wholeNumberValue, c.isNumber,
               (1...9).contains(d) || (d == 0 && count != nil) {
                count = (count ?? 0) * 10 + d
                return .none
            }
            if pendingG {
                pendingG = false
                if c == "g" {
                    moveCursor(toLine: (count ?? 1) - 1)
                }
                count = nil
                return .none
            }
            switch c {
            case "g": pendingG = true; return .none
            case "j":
                moveCursor(toLine: lineOfCursor() + max(count ?? 1, 1))
            case "k":
                moveCursor(toLine: lineOfCursor() - max(count ?? 1, 1))
            case "G":
                let starts = lineStarts()
                moveCursor(toLine: count.map { min($0 - 1, starts.count - 1) }
                                   ?? starts.count - 1)
            case "z":
                // zz: treat a doubled z like the g prefix, minimally.
                if pending == "z" { pending = nil; count = nil; return .scrollCenter }
                pending = "z"
                return .none
            default: break
            }
            pending = nil
            count = nil
            return .none
        }
    }
```

- [ ] **Step 4: Прогон** — VimEngineTests → 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/VimEngine.swift Tests/CoveyAppTests/VimEngineTests.swift
git commit -m "feat(covey): VimEngine preview mode - scroll-only navigation"
```

---

### Task 4: Зона issue всегда в фокусе, чорды сквозь поля

**Files:**
- Modify: `Sources/covey/KeyRouter.swift` (минус inspectorEnter)
- Modify: `Sources/covey/AppModel.swift` (минус .inspectorEnter, tick в selectInspectorTab)
- Modify: `Sources/covey/Views/ContentView.swift` (monitor)
- Modify: `Sources/covey/Views/IssuePane.swift` (минус onExitCommand у Title)
- Test: `Tests/CoveyAppTests/KeyRouterTests.swift`, `Tests/CoveyAppTests/AppModelChromeTests.swift`

- [ ] **Step 1: Тесты-правки (падают после кода — здесь наоборот: сначала
  правим тесты под новое поведение)**

KeyRouterTests.testInspectorZoneChords — УДАЛИТЬ строки:

```swift
        // Enter dives from the zone's normal mode into the issue form.
        XCTAssertEqual(KeyRouter.route(special(.enter), context: insp), .inspectorEnter)
```

AppModelChromeTests.testCycleFocusWalksInspectorTabsAsZones — вернуть
автофокус:

```swift
        let tickBefore = model.issueFocusTick
        model.apply(.cycleFocus(forward: true))   // -> inspector, issue zone
        XCTAssertEqual(model.focus, .inspector)
        XCTAssertEqual(model.inspectorTab, .issue)
        XCTAssertEqual(model.issueFocusTick, tickBefore + 1,
                       "issue zone always lands in the form")
```

(строки с `model.apply(.inspectorEnter)` удалить).

- [ ] **Step 2: Реализация**

- KeyRouter: удалить `case inspectorEnter` из KeyAction и ветку
  `if input.special == .enter, context.mode == .normal { return .inspectorEnter }`.
- AppModel: удалить кейс `.inspectorEnter` из apply; `selectInspectorTab`:

```swift
    public func selectInspectorTab(_ tab: InspectorTab) {
        inspectorTab = tab
        // The issue zone is always "in the form": focus the title at once.
        if tab == .issue { issueFocusTick += 1 }
    }
```

  и в `cycleFocus` зона issue уже вызывает `selectInspectorTab(.issue)` —
  проверить, что осталось так.
- ContentView, key-monitor — ПЕРЕД строкой
  `if let responder = event.window?.firstResponder, responder is NSTextView {`:

```swift
                // Inspector zone chords must escape its text fields: ⌃h/l/j/k
                // never type text (the zone's emacs bindings are sacrificed).
                if model.focus == .inspector,
                   event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control,
                   let raw = event.charactersIgnoringModifiers?.first,
                   ["h", "l", "j", "k"].contains(latinize(raw)) {
                    let context = KeyRouter.Context(mode: model.inputMode,
                                                    focus: model.focus,
                                                    vimMode: model.vimMode,
                                                    sheetOpen: model.modal != nil)
                    if let action = KeyRouter.route(keyInput(from: event), context: context) {
                        model.apply(action)
                        return nil
                    }
                }
```

- IssuePane: удалить `.onExitCommand { titleFocused = false }` у Title
  (Esc в Title — no-op) и `.onExitCommand { bodyFocused = false }` у body
  (Esc в body — дело vim-движка, Task 5 заменяет поле целиком).

- [ ] **Step 3: Прогон**

Run: `swift test --filter "KeyRouterTests|AppModelChromeTests" 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 4: Commit (user)**

```bash
git add Sources/covey/KeyRouter.swift Sources/covey/AppModel.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/IssuePane.swift Tests/CoveyAppTests/KeyRouterTests.swift Tests/CoveyAppTests/AppModelChromeTests.swift
git commit -m "feat(covey): issue zone always in-form, zone chords escape text fields"
```

---

### Task 5: VimEditor (вью) + интеграция

**Files:**
- Create: `Sources/covey/Views/VimEditor.swift`
- Modify: `Sources/covey/Views/IssuePane.swift` (body → VimEditor)
- Modify: `Sources/covey/AppModel.swift` (`inspectorVimBadge`)
- Modify: `Sources/covey/Views/StatusBar.swift` (бейдж 4 режимов + цвета)
- Test: полный `swift test` (вью-обвязка — смоук)

**Interfaces:**
- Consumes: VimEngine (Tasks 1-3), `parseNote`/`NoteLine` (NoteModel),
  `Tokens`, `latinize`.
- Produces: `VimEditor(text: Binding<String>, modeBadge: Binding<String>, tk: Tokens, onSwitchField: @escaping (Bool) -> Void)`;
  `AppModel.inspectorVimBadge: String?`.

- [ ] **Step 1: VimEditor** — создать `Sources/covey/Views/VimEditor.swift`:

```swift
import SwiftUI
import AppKit
import CoveyKit

/// Reusable vim-lite markdown editor: NORMAL/INSERT/VISUAL over the raw
/// text (NSTextView with a line-number ruler) and a PREVIEW mode rendering
/// obsidian-style markdown with scroll-only navigation.
struct VimEditor: View {
    @Binding var text: String
    @Binding var modeBadge: String
    var tk: Tokens
    var onSwitchField: (Bool) -> Void

    @State private var box = VimBox()

    var body: some View {
        Group {
            if box.isPreview {
                VimPreview(box: box, text: text, tk: tk)
            } else {
                VimTextRepresentable(box: box, text: $text,
                                     onSwitchField: onSwitchField)
            }
        }
        .background(tk.surf2, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(box.focused ? tk.accent.opacity(0.7) : tk.bd2))
        .onChange(of: box.badge) { _, badge in modeBadge = badge }
    }
}

/// Shared mutable home of the engine: the NSView layer and the SwiftUI
/// preview both talk to the same state.
@Observable
final class VimBox {
    var engine = VimEngine()
    var badge = "INSERT"
    var focused = false
    var scrollCenterTick = 0

    var isPreview: Bool { engine.mode == .preview }

    func refreshBadge() {
        switch engine.mode {
        case .normal: badge = "NORMAL"
        case .insert: badge = "INSERT"
        case .visual: badge = "VISUAL"
        case .preview: badge = "PREVIEW"
        }
    }

    /// Feed one input; applies clipboard/scroll effects. Returns the
    /// switch-field request if any.
    func handle(_ input: VimInput) -> Bool? {
        let effect = engine.handle(input, pasteboard: {
            NSPasteboard.general.string(forType: .string)
        })
        refreshBadge()
        switch effect {
        case .setPasteboard(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        case .scrollCenter:
            scrollCenterTick += 1
        case .switchField(let forward):
            return forward
        case .none: break
        }
        return nil
    }
}

// MARK: - text modes (normal/insert/visual)

private struct VimTextRepresentable: NSViewRepresentable {
    let box: VimBox
    @Binding var text: String
    var onSwitchField: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(box: box, text: $text, onSwitchField: onSwitchField)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = VimNSTextView()
        view.box = box
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.drawsBackground = false
        view.allowsUndo = true
        view.isRichText = false
        view.string = text
        box.engine.syncFromView(text: text, cursor: 0)
        box.refreshBadge()

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true

        let ruler = LineNumberRuler(scrollView: scroll, textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? VimNSTextView else { return }
        if view.string != text, box.engine.mode == .insert {
            // External draft change (project switch): reload.
            view.string = text
            box.engine.syncFromView(text: text, cursor: 0)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let box: VimBox
        var text: Binding<String>
        let onSwitchField: (Bool) -> Void
        init(box: VimBox, text: Binding<String>, onSwitchField: @escaping (Bool) -> Void) {
            self.box = box; self.text = text; self.onSwitchField = onSwitchField
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            box.engine.syncFromView(text: view.string,
                                    cursor: view.selectedRange().location)
        }

        /// Apply engine state back into the view after a normal/visual key.
        func sync(into view: NSTextView) {
            if view.string != box.engine.text {
                view.string = box.engine.text
                text.wrappedValue = box.engine.text
            }
            let c = box.engine.cursor
            if case .visual(let anchor) = box.engine.mode {
                let lo = min(anchor, c)
                let hi = min(max(anchor, c) + 1, (view.string as NSString).length)
                view.setSelectedRange(NSRange(location: lo, length: hi - lo))
            } else {
                view.setSelectedRange(NSRange(location: min(c, (view.string as NSString).length), length: 0))
            }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

/// NSTextView that gives non-insert keys to the engine.
final class VimNSTextView: NSTextView {
    weak var box: VimBox?
    weak var coordinator: VimTextRepresentable.Coordinator?

    override func becomeFirstResponder() -> Bool {
        box?.focused = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        box?.focused = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard let box, let coordinator else { return super.keyDown(with: event) }
        // ⌘/⌃-chords belong to the app (zone cycling, form shortcuts).
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            return super.keyDown(with: event)
        }
        let input = vimInput(from: event)
        if box.engine.mode == .insert {
            if input == .escape {
                if let forward = box.handle(.escape) { onSwitch(forward) }
                coordinator.sync(into: self)
                return
            }
            return super.keyDown(with: event)   // native typing
        }
        // In insert the engine already synced via textDidChange; before a
        // normal/visual key make sure it sees the current caret.
        box.engine.syncFromView(text: string, cursor: selectedRange().location)
        if let forward = box.handle(input) { onSwitch(forward) }
        coordinator.sync(into: self)
    }

    private func onSwitch(_ forward: Bool) {
        coordinator?.onSwitchField(forward)
    }

    private func vimInput(from event: NSEvent) -> VimInput {
        switch event.keyCode {
        case 53: return .escape
        case 48: return event.modifierFlags.contains(.shift) ? .shiftTab : .tab
        default:
            let raw = event.charactersIgnoringModifiers?.first ?? " "
            return .char(latinize(raw))
        }
    }
}

/// Classic line-number gutter for an NSTextView.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func needsRedraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager,
              let container = tv.textContainer else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let content = tv.string as NSString
        var line = content.substring(to: lm.characterIndexForGlyph(at: glyphs.location))
            .components(separatedBy: "\n").count
        var glyph = glyphs.location
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        while glyph < NSMaxRange(glyphs) {
            var effective = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let charRange = lm.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
            let isLineStart = charRange.location == 0
                || content.character(at: charRange.location - 1) == 0x0A
            if isLineStart {
                let y = lineRect.minY - visible.minY + tv.textContainerInset.height
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
                line += 1
            }
            glyph = NSMaxRange(effective)
        }
    }
}

// MARK: - preview

/// Obsidian-style read view: line numbers + parseNote line rendering;
/// scroll follows the engine's cursor line.
private struct VimPreview: View {
    let box: VimBox
    let text: String
    let tk: Tokens
    @FocusState private var focused: Bool

    var body: some View {
        let lines = parseNote(text)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(tk.t4)
                                .frame(width: 26, alignment: .trailing)
                            render(line)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .background(idx == box.engine.lineOfCursor()
                                    ? tk.surf3 : .clear)
                        .id(idx)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: box.engine.cursor) { _, _ in
                proxy.scrollTo(box.engine.lineOfCursor())
            }
            .onChange(of: box.scrollCenterTick) { _, _ in
                proxy.scrollTo(box.engine.lineOfCursor(), anchor: .center)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            let input: VimInput = press.key == .escape ? .escape
                : .char(latinize(press.characters.first ?? " "))
            _ = box.handle(input)
            return .handled
        }
    }

    @ViewBuilder
    private func render(_ line: NoteLine) -> some View {
        switch line {
        case .heading(let level, let textLine):
            Text(textLine)
                .font(.system(size: level == 1 ? 16 : 14, weight: .bold))
        case .task(let done, let textLine):
            HStack(spacing: 6) {
                Text(done ? "☑" : "☐")
                Text(textLine).strikethrough(done)
                    .foregroundStyle(done ? AnyShapeStyle(.secondary)
                                          : AnyShapeStyle(.primary))
            }
            .font(.callout)
        case .bullet(let textLine):
            HStack(spacing: 6) { Text("•"); Text(textLine) }.font(.callout)
        case .text(let textLine):
            Text(textLine).font(.callout)
        case .blank:
            Text(" ").font(.caption2)
        }
    }
}
```

ВНИМАНИЕ: `parseNote` должен рендерить РОВНО одну NoteLine на строку
сырца (иначе номера строк съедут) — проверить его реализацию в
NoteModel; если пустые строки схлопываются, дополнить parseNote-вызов
собственным построчным мапом (line-by-line: `text.components(separatedBy: "\n").map { parseNote($0).first ?? .blank }`).

- [ ] **Step 2: IssuePane** — заменить body-TextEditor:

```swift
            VimEditor(text: Binding(
                get: { draft.body },
                set: { v in update { $0.body = v } }),
                      modeBadge: Binding(
                get: { model.inspectorVimBadge ?? "NORMAL" },
                set: { model.inspectorVimBadge = $0 }),
                      tk: tk,
                      onSwitchField: { _ in
                bodyFocused = false
                titleFocused = true
            })
            .focused($bodyFocused)
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 140)
```

(старые `.background/.overlay/.tint/.onKeyPress(.tab)/.scrollContentBackground`
у body удалить — рамку рисует сам VimEditor).

`syncEditing()` больше не пишет INSERT от bodyFocused (бейджем body
управляет VimEditor): `model.inspectorEditing = titleFocused`.

- [ ] **Step 3: AppModel + StatusBar**

AppModel (рядом с inspectorEditing):

```swift
    /// Vim mode badge from the issue body editor ("NORMAL"/"INSERT"/...);
    /// nil when the editor is not mounted.
    public var inspectorVimBadge: String?
```

StatusBar — заменить INSERT/NORMAL блок:

```swift
            let badge = model.inspectorVimBadge
                ?? ((model.inspectorEditing || model.noteState.editing) ? "INSERT" : "NORMAL")
            Text(badge)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(badgeColor(badge))
```

и приватный хелпер:

```swift
    private func badgeColor(_ badge: String) -> Color {
        switch badge {
        case "INSERT": return tk.warn
        case "VISUAL": return tk.accent
        case "PREVIEW": return tk.ok
        default: return tk.t4
        }
    }
```

- [ ] **Step 4: Полный прогон**

Run: `swift build 2>&1 | grep -c error:; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 ошибок, 0 failures.

- [ ] **Step 5: Commit (user)**

```bash
git add Sources/covey/Views/VimEditor.swift Sources/covey/Views/IssuePane.swift Sources/covey/AppModel.swift Sources/covey/Views/StatusBar.swift
git commit -m "feat(covey): VimEditor view - line numbers, markdown preview, badge"
```

---

### Task 6: Смоук (user) + docs commit

Рестарт демона НЕ нужен.

- [ ] **Step 1: Смоук по спеке §6**

1. Переход на Issue — курсор в Title; ⌃h/⌃l ИЗ полей уводят по зонам;
   ⌘M/⌘O при вводе.
2. Body: INSERT-печать; Esc → NORMAL; hjkl/w/b/0/$/5j/12G; i/a/o/A.
3. dd/p, yy/p, x, dw, cw, v+движение (VISUAL в футере, акцент), y/d.
4. `gp` → PREVIEW (зелёный в футере): MD-рендер, номера строк,
   заголовки/чекбоксы/списки; j/k/5j/gg/G/12G/zz; Esc → сырец.
5. Номера строк в текстовых режимах (ruler слева).
6. Tab из body-NORMAL → Title.

- [ ] **Step 2: Docs commit (user)**

```bash
git add docs/superpowers/specs/2026-07-06-covey-vim-editor-design.md docs/superpowers/plans/2026-07-06-covey-vim-editor.md
git commit -m "docs: slice 26 spec and plan — vim editor with md preview"
```
