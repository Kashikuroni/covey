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

    func testEndOfWordMotion() {
        var e = engine("foo bar baz", cursor: 0)
        feed(&e, "e"); XCTAssertEqual(e.cursor, 2, "e -> last char of 'foo'")
        feed(&e, "e"); XCTAssertEqual(e.cursor, 6, "e -> last char of 'bar'")
        feed(&e, "e"); XCTAssertEqual(e.cursor, 10, "e -> last char of 'baz'")
        feed(&e, "e"); XCTAssertEqual(e.cursor, 10, "e clamps at the last word end")
    }

    func testPunctuationAwareWordMotions() {
        var e = engine("foo.bar baz", cursor: 0)
        feed(&e, "w"); XCTAssertEqual(e.cursor, 3, "w stops at the punctuation run '.'")
        feed(&e, "w"); XCTAssertEqual(e.cursor, 4, "w -> 'bar'")
        feed(&e, "e"); XCTAssertEqual(e.cursor, 6, "e -> end of 'bar'")
        feed(&e, "b"); XCTAssertEqual(e.cursor, 4, "b -> start of 'bar'")
        feed(&e, "b"); XCTAssertEqual(e.cursor, 3, "b -> the '.' run")
    }

    func testBigWordMotions() {
        var e = engine("foo.bar baz", cursor: 0)
        feed(&e, "W"); XCTAssertEqual(e.cursor, 8, "W is whitespace-delimited: skips 'foo.bar'")
        feed(&e, "B"); XCTAssertEqual(e.cursor, 0, "B -> start of 'foo.bar'")
        feed(&e, "E"); XCTAssertEqual(e.cursor, 6, "E -> end of the WORD 'foo.bar'")
    }

    func testFirstNonBlankAndDeleteToWordEnd() {
        var e = engine("   hi\nyo", cursor: 4)
        feed(&e, "^"); XCTAssertEqual(e.cursor, 3, "^ -> first non-blank")
        feed(&e, "0"); XCTAssertEqual(e.cursor, 0)
        var d = engine("foo bar", cursor: 0)
        _ = feedFx(&d, "de")
        XCTAssertEqual(d.text, " bar", "de deletes through the end of 'foo' inclusive")
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

    func testVisualLine() {
        var e = engine("one\ntwo\nthree", cursor: 0)
        _ = feedFx(&e, "V")
        XCTAssertEqual(e.mode, .visualLine(anchor: 0), "V enters line-wise visual")
        _ = feedFx(&e, "j")                          // extend down one line
        let fx = feedFx(&e, "y")
        XCTAssertTrue(fx.contains(.setPasteboard("one\ntwo\n")), "V y yanks whole lines")
        XCTAssertEqual(e.mode, .normal)
        XCTAssertEqual(e.text, "one\ntwo\nthree", "yank does not edit")

        var d = engine("one\ntwo\nthree", cursor: 0)
        _ = feedFx(&d, "Vjd")
        XCTAssertEqual(d.text, "three", "V j d deletes both whole lines")

        var c = engine("one\ntwo", cursor: 0)
        _ = feedFx(&c, "Vc")
        XCTAssertEqual(c.mode, .insert)
        XCTAssertEqual(c.text, "\ntwo", "V c clears the line, keeps a blank line")

        var x = engine("one\ntwo\nthree", cursor: 4)  // line 1 ("two")
        _ = feedFx(&x, "Vx")
        XCTAssertEqual(x.text, "one\nthree", "V x deletes the current whole line")
    }

    func testCharwiseVisualStillCharwise() {
        // v selects characters, not lines (regression guard for v vs V).
        var e = engine("abcdef", cursor: 1)
        _ = feedFx(&e, "v")
        XCTAssertEqual(e.mode, .visual(anchor: 1))
        _ = feedFx(&e, "l")
        let fx = feedFx(&e, "y")
        XCTAssertTrue(fx.contains(.setPasteboard("bc")), "v y is charwise inclusive")
    }

    func testPendingResetOnInvalidMotion() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "dq")
        XCTAssertEqual(e.text, "abc", "invalid motion cancels the operator")
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "bc", "engine is usable right after")
    }

    func testPreviewIsNonInteractive() {
        // Preview is a pure read view: no cursor roaming, no scroll keys.
        var e = engine("l0\nl1\nl2\nl3\nl4", cursor: 0)
        _ = feedFx(&e, "gp")
        XCTAssertEqual(e.mode, .preview)
        _ = feedFx(&e, "j")
        XCTAssertEqual(e.lineOfCursor(), 0, "j does not move the cursor in preview")
        _ = feedFx(&e, "3j")
        XCTAssertEqual(e.lineOfCursor(), 0)
        _ = feedFx(&e, "gg")
        XCTAssertEqual(e.lineOfCursor(), 0)
        _ = feedFx(&e, "G")
        XCTAssertEqual(e.lineOfCursor(), 0)
        let fx = feedFx(&e, "zz")
        XCTAssertFalse(fx.contains(.scrollCenter), "zz no longer scrolls in preview")
        _ = feedFx(&e, "x")
        XCTAssertEqual(e.text, "l0\nl1\nl2\nl3\nl4", "preview never edits")
        XCTAssertEqual(e.mode, .preview, "stray keys keep the read view")
        _ = e.handle(.escape)
        XCTAssertEqual(e.mode, .normal)
    }

    func testPreviewEntersNormalToEdit() {
        // Read-only: i/a/o are inert — you drop to NORMAL (enter/esc) first.
        var e = engine("ab\ncd", cursor: 0)
        _ = feedFx(&e, "gp")
        _ = feedFx(&e, "i")
        XCTAssertEqual(e.mode, .preview, "i is inert in preview")
        _ = feedFx(&e, "a")
        XCTAssertEqual(e.mode, .preview, "a is inert in preview")
        _ = feedFx(&e, "o")
        XCTAssertEqual(e.mode, .preview, "o is inert in preview")
        XCTAssertEqual(e.text, "ab\ncd", "preview never edits")
        _ = e.handle(.char("\n"))
        XCTAssertEqual(e.mode, .normal, "enter drops to normal")
    }

    func testStartInPreview() {
        var e = VimEngine(text: "a\nb", startInPreview: true)
        XCTAssertEqual(e.mode, .preview)
        _ = e.handle(.escape)
        XCTAssertEqual(e.mode, .normal)
    }

    func testTabSwitchesFieldOnlyFromNormal() {
        var e = engine("x")
        XCTAssertEqual(e.handle(.tab), .switchField(forward: true))
        XCTAssertEqual(e.handle(.shiftTab), .switchField(forward: false))
        feed(&e, "i")
        XCTAssertEqual(e.handle(.tab), .none, "insert keeps tab as typing")
    }

    func testUndoRedoNormalEdit() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "x")                    // delete 'a'
        XCTAssertEqual(e.text, "bc")
        _ = feedFx(&e, "u")                    // undo
        XCTAssertEqual(e.text, "abc")
        XCTAssertEqual(e.mode, .normal)
        _ = e.handle(.redo)                    // ⌃r
        XCTAssertEqual(e.text, "bc", "redo reapplies the delete")
    }

    func testUndoUndoesWholeInsertSession() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "i")                    // enter insert (snapshots "abc")
        e.syncFromView(text: "XYabc", cursor: 2)   // native typing round-trips here
        _ = e.handle(.escape)
        XCTAssertEqual(e.text, "XYabc")
        _ = feedFx(&e, "u")
        XCTAssertEqual(e.text, "abc", "one u undoes the entire insert")
    }

    func testUndoLinewiseDelete() {
        var e = engine("one\ntwo\nthree", cursor: 0)
        _ = feedFx(&e, "dd")
        XCTAssertEqual(e.text, "two\nthree")
        _ = feedFx(&e, "u")
        XCTAssertEqual(e.text, "one\ntwo\nthree")
    }

    func testNewEditClearsRedo() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "x")                    // "bc"
        _ = feedFx(&e, "u")                    // "abc"
        _ = feedFx(&e, "x")                    // "bc" — a fresh edit drops the redo
        _ = e.handle(.redo)                    // nothing to redo
        XCTAssertEqual(e.text, "bc")
    }

    func testYankDoesNotSnapshot() {
        var e = engine("abc", cursor: 0)
        _ = feedFx(&e, "yy")                   // pure copy — no edit
        _ = feedFx(&e, "u")                    // nothing to undo
        XCTAssertEqual(e.text, "abc")
    }
}
