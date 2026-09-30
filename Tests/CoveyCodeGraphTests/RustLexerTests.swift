import XCTest
@testable import CoveyCodeGraph

final class RustLexerTests: XCTestCase {
    func testCommentsIncludingNestedBlocksAreBlanked() {
        let source = "use a; // use b;\n/* outer /* inner */ still */ use c;\n"
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["use", "a", "use", "c"])
    }

    func testStringsRawStringsAndByteStringsAreBlanked() {
        let source = """
        let a = "x // y \\" z";
        let b = r#"quoted "inner" // no"#;
        let c = b"bytes"; let d = br##"x"#y"##;
        let e = c"cstr";
        let f = r#type;
        """
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed),
                       ["let", "a", "let", "b", "let", "c", "let", "d", "let", "e", "let", "f", "r", "type"])
    }

    func testLifetimesStayAndCharsAreBlanked() {
        let source = """
        fn f<'a>(x: &'a str) -> char {
            let q = '"'; let e = '\\''; let u = '\\u{1F600}'; let m = 'é'; let n = b'\\n';
            'outer: loop { break 'outer; }
            'z'
        }
        """
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed),
                       ["fn", "f", "a", "x", "a", "str", "char",
                        "let", "q", "let", "e", "let", "u", "let", "m", "let", "n",
                        "outer", "loop", "break", "outer"])
    }

    func testMultilineStringKeepsLaterLineNumbers() {
        let source = "let s = \"line1\nuse fake;\";\nuse crate::x;"
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertFalse(survivingWords(lexed).contains("fake"))
        XCTAssertEqual(lineOf("crate", in: lexed), 3)
    }
}
