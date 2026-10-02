import XCTest
@testable import CoveyCodeGraph

final class ScriptLexerTests: XCTestCase {
    func testCommentsStringsAndTemplatesAreBlankedButSubstitutionsStay() {
        let source = """
        import { a } from './a' // from './b'
        /* import c from './c' */
        const t = `text ${ value + `inner ${deep}` } more`
        const s = "double" + 'single'
        """
        let lexed = ScriptLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed),
                       ["import", "a", "from", "const", "t", "value", "deep", "const", "s"])
        XCTAssertEqual(lexed.strings.map(\.value), ["./a", "double", "single"])
    }

    func testSubstitutionFreeTemplateIsKeptAsAString() {
        let lexed = ScriptLexer.lex("const m = await import(`./lazy`)")
        XCTAssertEqual(survivingWords(lexed), ["const", "m", "await", "import"])
        XCTAssertEqual(lexed.strings, [StringLiteral(offset: 23, value: "./lazy")])
    }

    func testRegexLiteralsAreBlankedAndDivisionIsNot() {
        let source = #"""
        const r = /it's "not" a string/g.test(x)
        const d = total / count / 2
        return /\/\/ comment?/.exec(y)
        if (ok) x = a[1] / b
        """#
        let lexed = ScriptLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed),
                       ["const", "r", "test", "x", "const", "d", "total", "count", "2",
                        "return", "exec", "y", "if", "ok", "x", "a", "1", "b"])
        XCTAssertTrue(lexed.strings.isEmpty)
    }

    func testJSXClosingTagIsNotARegex() {
        let lexed = ScriptLexer.lex("const el = <div>{name}</div>; const q = 'x'")
        XCTAssertEqual(survivingWords(lexed), ["const", "el", "div", "name", "div", "const", "q"])
        XCTAssertEqual(lexed.strings.map(\.value), ["x"])
    }

    /// A backslash escapes the whole `\r\n` line end inside a quoted string,
    /// so the string continues and its content stays blanked.
    func testBackslashCRLFContinuesAString() {
        let source = "const s = 'a\\\r\nimport h';\nimport('./i')\n"
        let lexed = ScriptLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["const", "s", "import"])
        XCTAssertEqual(lexed.strings.map(\.value), ["a\\\r\nimport h", "./i"])
    }

    func testVeryLongMinifiedLineStaysCorrect() {
        let long = String(repeating: "f(/x/,a/b,'s');", count: 20_000)
            + String(repeating: "(/", count: 20_000)
        let source = long + "\nimport z from './z'"
        let lexed = ScriptLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(lineOf("z", in: lexed), 2)
        XCTAssertEqual(lexed.strings.last?.value, "./z")
        XCTAssertEqual(lexed.strings.count, 20_001)
    }
}
