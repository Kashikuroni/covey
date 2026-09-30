import XCTest
@testable import CoveyCodeGraph

final class PythonLexerTests: XCTestCase {
    func testCommentsDocstringsAndPrefixedStringsAreBlanked() {
        let source = #"""
        import a  # import b
        x = 'import c'; y = "import d"
        z = rb'\x00' + f"{e}" + U'u' + Rb"raw\" still"
        '''
        import e
        '''
        """import f"""
        import g
        """#
        let lexed = PythonLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["import", "a", "x", "y", "z", "import", "g"])
        XCTAssertEqual(lineOf("g", in: lexed), 8)
    }

    func testAPrefixMustBeTheWholeWord() {
        let lexed = PythonLexer.lex(#"abr"x" + br"y" + rb"#)
        XCTAssertEqual(survivingWords(lexed), ["abr", "rb"])
    }

    func testBackslashNewlineContinuesAString() {
        let source = "s = 'a\\\nimport h'\nimport i"
        let lexed = PythonLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["s", "import", "i"])
        XCTAssertEqual(lineOf("i", in: lexed), 3)
    }

    func testUnterminatedStringEndsAtTheLine() {
        let lexed = PythonLexer.lex("s = 'open\nimport j")
        XCTAssertEqual(survivingWords(lexed), ["s", "import", "j"])
    }
}
