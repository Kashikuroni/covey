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
    enum Mode: Equatable { case normal, insert, visual(anchor: Int), visualLine(anchor: Int), preview }

    private(set) var chars: [Character]
    private(set) var cursor: Int = 0
    private(set) var mode: Mode = .normal
    private(set) var pending: Character?   // d / c / y awaiting a motion
    private(set) var pendingG = false      // g prefix (gg / gp)
    private(set) var count: Int?           // motion count (5j, 12G)

    var text: String { String(chars) }

    init(text: String = "", startInPreview: Bool = false) {
        chars = Array(text)
        if startInPreview { mode = .preview }
    }

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
        case .normal, .visual, .visualLine:
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
                return finishMotion(.linewise(toLine: target, firstCol: true))
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
        return handleEdit(c, pasteboard: pasteboard)
    }

    // MARK: - motions

    private enum MotionKind {
        case charwise(to: Int, inclusive: Bool)
        /// firstCol: G/gg land on column 0; j/k keep the column.
        case linewise(toLine: Int, firstCol: Bool = false)
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
        case "^": return .charwise(to: firstNonBlank(), inclusive: false)
        case "$": return .charwise(to: max(lineStart(cursor), lineEnd(cursor) - 1), inclusive: true)
        case "w": return .charwise(to: wordStartForward(from: cursor, times: n, big: false), inclusive: false)
        case "W": return .charwise(to: wordStartForward(from: cursor, times: n, big: true), inclusive: false)
        case "b": return .charwise(to: wordStartBack(from: cursor, times: n, big: false), inclusive: false)
        case "B": return .charwise(to: wordStartBack(from: cursor, times: n, big: true), inclusive: false)
        case "e": return .charwise(to: wordEndForward(from: cursor, times: n, big: false), inclusive: true)
        case "E": return .charwise(to: wordEndForward(from: cursor, times: n, big: true), inclusive: true)
        case "j": return .linewise(toLine: min(line + n, starts.count - 1))
        case "k": return .linewise(toLine: max(line - n, 0))
        case "G":
            return .linewise(toLine: count.map { min($0 - 1, starts.count - 1) }
                                   ?? starts.count - 1,
                             firstCol: true)
        default: return nil
        }
    }

    private mutating func finishMotion(_ motion: MotionKind) -> VimEffect {
        defer { count = nil }
        if pending != nil { return applyOperator(to: motion) }
        switch motion {
        case .charwise(let to, _):
            cursor = to
            if mode == .normal { clampToLine() }
        case .linewise(let toLine, let firstCol):
            moveCursor(toLine: toLine)
            if firstCol { cursor = lineStart(cursor) }
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

    // Vim word model: keyword chars (letters/digits/_) form a "word", other
    // non-blanks form a "punct" run; `big` (W/B/E) collapses those so a WORD is
    // any whitespace-delimited run.
    private enum WClass: Equatable { case blank, word, punct }
    private func wclass(_ i: Int, big: Bool) -> WClass {
        let c = chars[i]
        if c.isWhitespace { return .blank }
        if big || c.isLetter || c.isNumber || c == "_" { return .word }
        return .punct
    }

    /// w / W: start of the nth next word.
    private func wordStartForward(from: Int, times: Int, big: Bool) -> Int {
        var i = min(max(from, 0), chars.count)
        for _ in 0..<times {
            guard i < chars.count else { break }
            let c0 = wclass(i, big: big)
            if c0 != .blank { while i < chars.count && wclass(i, big: big) == c0 { i += 1 } }
            while i < chars.count && wclass(i, big: big) == .blank { i += 1 }
        }
        return min(i, max(0, chars.count - 1))
    }

    /// e / E: end (last char) of the nth next word — inclusive for operators.
    private func wordEndForward(from: Int, times: Int, big: Bool) -> Int {
        var i = from
        for _ in 0..<times {
            i += 1
            while i < chars.count && wclass(i, big: big) == .blank { i += 1 }
            guard i < chars.count else { i = max(0, chars.count - 1); break }
            let c = wclass(i, big: big)
            while i + 1 < chars.count && wclass(i + 1, big: big) == c { i += 1 }
        }
        return max(0, min(i, max(0, chars.count - 1)))
    }

    /// b / B: start of the nth previous word.
    private func wordStartBack(from: Int, times: Int, big: Bool) -> Int {
        var i = min(from, chars.count)
        for _ in 0..<times {
            i -= 1
            while i >= 0 && wclass(i, big: big) == .blank { i -= 1 }
            guard i >= 0 else { i = 0; break }
            let c = wclass(i, big: big)
            while i - 1 >= 0 && wclass(i - 1, big: big) == c { i -= 1 }
        }
        return max(0, i)
    }

    /// ^: first non-blank of the cursor's line (line start if all blank).
    private func firstNonBlank() -> Int {
        let s = lineStart(cursor), e = lineEnd(cursor)
        var i = s
        while i < e && chars[i].isWhitespace { i += 1 }
        return i < e ? i : s
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

    // MARK: - edits

    private mutating func handleEdit(
        _ c: Character, pasteboard: () -> String?
    ) -> VimEffect {
        // Visual-mode operators act on the selection immediately.
        if case .visual(let anchor) = mode, "dxyc".contains(c) {
            return applyVisual(c, anchor: anchor)
        }
        if case .visualLine(let anchor) = mode, "dxyc".contains(c) {
            return applyVisualLine(c, anchor: anchor)
        }
        if enterInsert(c) { resetPrefixes(); return .none }
        switch c {
        case "v":
            mode = .visual(anchor: cursor)
            resetPrefixes()
            return .none
        case "V":
            mode = .visualLine(anchor: cursor)
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
        if e < chars.count { e += 1 }             // take the trailing newline
        else if s > 0 { chars.remove(at: s - 1); return finishDd(from: s - 1, line: line) }
        chars.removeSubrange(min(s, chars.count)..<min(e, chars.count))
        cursor = min(s, max(0, chars.count - 1))
        if chars.isEmpty { cursor = 0 }
        clampToLine()
        return .setPasteboard(line + "\n")
    }

    private mutating func finishDd(from s: Int, line: String) -> VimEffect {
        // Last line: its content plus the newline BEFORE it were removed.
        chars.removeSubrange(min(s, chars.count)..<chars.count)
        cursor = max(0, min(s, chars.count) - 0)
        if chars.isEmpty { cursor = 0 } else { cursor = min(cursor, chars.count - 1) }
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
            lo = max(lo, 0)
            hi = min(hi, chars.count)
            if lo == hi { return .none }
            let cut = String(chars[lo..<hi])
            if op == "y" {
                cursor = lo
                return .setPasteboard(cut)
            }
            chars.removeSubrange(lo..<hi)
            cursor = lo
            if op == "c" { mode = .insert } else { clampToLine() }
            return .setPasteboard(cut)
        case .linewise(let toLine, _):
            let starts = lineStarts()
            let target = min(max(toLine, 0), starts.count - 1)
            let cur = lineOfCursor()
            let a = min(cur, target)
            let b = max(cur, target)
            let s = starts[a]
            var e = lineEnd(starts[b])
            let cut = String(chars[s..<e]) + "\n"
            if op == "y" {
                cursor = s
                return .setPasteboard(cut)
            }
            if e < chars.count { e += 1 }
            else if s > 0 { chars.remove(at: s - 1); e = chars.count }
            chars.removeSubrange(min(s, chars.count)..<min(e, chars.count))
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

    private func lineIndex(of offset: Int) -> Int {
        var line = 0
        for k in 0..<min(max(offset, 0), chars.count) where chars[k] == "\n" { line += 1 }
        return line
    }

    /// V-mode d/x/y/c over whole lines from the anchor's line to the cursor's.
    private mutating func applyVisualLine(_ op: Character, anchor: Int) -> VimEffect {
        let starts = lineStarts()
        let lo = min(lineIndex(of: anchor), lineOfCursor())
        let hi = max(lineIndex(of: anchor), lineOfCursor())
        let s = starts[lo]
        var e = lineEnd(starts[hi])
        let cut = String(chars[s..<e]) + "\n"
        mode = .normal
        resetPrefixes()
        if op == "y" {
            cursor = s
            clampToLine()
            return .setPasteboard(cut)
        }
        if e < chars.count { e += 1 }                 // include the trailing \n
        else if s > 0 { chars.remove(at: s - 1); e = chars.count }
        chars.removeSubrange(min(s, chars.count)..<min(e, chars.count))
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

    private mutating func paste(before: Bool, pasteboard: () -> String?) -> VimEffect {
        guard let clip = pasteboard(), !clip.isEmpty else { return .none }
        if clip.hasSuffix("\n") {   // linewise: insert as a whole line
            if before {
                let at = lineStart(cursor)
                chars.insert(contentsOf: Array(clip), at: at)
                cursor = at
            } else {
                let e = lineEnd(cursor)
                if e == chars.count {
                    chars.append("\n")
                    chars.append(contentsOf: Array(clip.dropLast()))
                    cursor = min(e + 1, max(0, chars.count - 1))
                } else {
                    chars.insert(contentsOf: Array(clip), at: e + 1)
                    cursor = e + 1
                }
            }
            clampToLine()
        } else {                    // charwise: after (p) / at (P) the cursor
            let e = lineEnd(cursor)
            let at = before ? min(cursor, e) : min(cursor + 1, e)
            chars.insert(contentsOf: Array(clip), at: at)
            cursor = at + clip.count - 1
            clampToLine()
        }
        return .none
    }

    // MARK: - preview: scroll-only navigation over the rendered text

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
                if c == "g" { moveCursor(toLine: (count ?? 1) - 1) }
                count = nil
                return .none
            }
            switch c {
            // Line-wise insert entries (the preview has no horizontal cursor):
            // i -> line start, a/A -> line end, o/O -> a fresh line below/above.
            case "i":
                cursor = lineStart(cursor)
                mode = .insert
                resetPrefixes()
                return .none
            case "a", "A":
                cursor = lineEnd(cursor)
                mode = .insert
                resetPrefixes()
                return .none
            case "o", "O":
                mode = .normal
                _ = enterInsert(c)
                resetPrefixes()
                return .none
            case "\n", "\r":
                mode = .normal
                cursor = lineStart(cursor)
                resetPrefixes()
                return .none
            case "g":
                pendingG = true
                return .none
            case "j":
                moveCursor(toLine: lineOfCursor() + max(count ?? 1, 1))
            case "k":
                moveCursor(toLine: lineOfCursor() - max(count ?? 1, 1))
            case "G":
                let starts = lineStarts()
                moveCursor(toLine: count.map { min($0 - 1, starts.count - 1) }
                                   ?? starts.count - 1)
            case "z":
                // zz: a doubled z centers the cursor line.
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
}
