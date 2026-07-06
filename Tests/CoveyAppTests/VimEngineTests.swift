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

    func testPreviewInsertEntries() {
        // No horizontal cursor in preview: entries are line-wise.
        var e = engine("ab\ncd", cursor: 0)
        _ = feedFx(&e, "gpj")
        _ = feedFx(&e, "i")
        XCTAssertEqual(e.mode, .insert)
        XCTAssertEqual(e.cursor, 3, "i starts at the line START")
        _ = e.handle(.escape)
        _ = feedFx(&e, "gp")
        _ = feedFx(&e, "a")
        XCTAssertEqual(e.mode, .insert)
        XCTAssertEqual(e.cursor, 5, "a starts at the line END")
        _ = e.handle(.escape)
        _ = feedFx(&e, "gp")
        _ = feedFx(&e, "o")
        XCTAssertEqual(e.mode, .insert)
        XCTAssertEqual(e.text, "ab\ncd\n")
        XCTAssertEqual(e.cursor, 6, "o opens a fresh line below")
        _ = e.handle(.escape)
        _ = feedFx(&e, "gp")
        _ = e.handle(.char("\n"))
        XCTAssertEqual(e.mode, .normal, "enter drops to normal on the line")
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
}
