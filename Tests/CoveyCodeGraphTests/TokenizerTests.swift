import XCTest
@testable import CoveyCodeGraph

final class TokenizerTests: XCTestCase {
    func testTokensCarryLineColumnAndDoubleColon() {
        let tokens = Tokenizer.tokens(RustLexer.lex("use a::b;\n  x"))
        XCTAssertEqual(tokens.map(\.text), ["use", "a", "::", "b", ";", "x"])
        XCTAssertEqual(tokens.map(\.kind), [.word, .word, .punct, .word, .punct, .word])
        XCTAssertEqual(tokens.last?.line, 2)
        XCTAssertEqual(tokens.last?.column, 2)
    }

    func testKeptStringsComeBackAsStringTokens() {
        let lexed = LexedSource(code: Array("f(       )".utf8),
                                strings: [StringLiteral(offset: 2, value: "./x")])
        let tokens = Tokenizer.tokens(lexed)
        XCTAssertEqual(tokens.map(\.text), ["f", "(", "./x", ")"])
        XCTAssertEqual(tokens[2].kind, .string)
    }

    func testWordLinesSkipNumbersAndRepeatsOnALine() {
        let lines = Tokenizer.wordLines(Tokenizer.tokens(RustLexer.lex("a a 1\nb a 2x")))
        XCTAssertEqual(lines, ["a": [1, 2], "b": [2]])
    }

    func testCRLFFilesNumberLinesLikeLF() {
        let source = "use a;\r\n// note\r\nuse b;\r\n"
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(lineOf("b", in: lexed), 3)
        XCTAssertEqual(Tokenizer.tokens(lexed).first { $0.text == "b" }?.column, 4)
    }

    func testRepairedNonUTF8TextLexesWithoutCrashing() {
        // What `String(decoding:)` makes of Latin-1 bytes: U+FFFD replacements.
        let source = String(decoding: [0x66, 0x6E, 0x20, 0xFF, 0xFE, 0x0A, 0x2F, 0x2A, 0xE9, 0x0A,
                                       0x2A, 0x2F, 0x20, 0x67], as: UTF8.self)
        for lexed in [RustLexer.lex(source), SwiftLexer.lex(source)] {
            assertSameShape(source, lexed)
            XCTAssertEqual(lineOf("g", in: lexed), 3)
        }
    }

    func testVeryLongLineKeepsLineNumbers() {
        let long = "let x = " + String(repeating: "a + ", count: 75_000) + "\"s // t\"; // tail"
        let source = long + "\nuse z;"
        let lexed = RustLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(lineOf("z", in: lexed), 2)
        XCTAssertFalse(survivingWords(lexed).contains("tail"))
    }
}
