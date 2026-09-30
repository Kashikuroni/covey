import XCTest
@testable import CoveyCodeGraph

final class SwiftLexerTests: XCTestCase {
    func testNestedCommentsAndStringsAreBlanked() {
        let source = "/* a /* b */ c */ struct A {}\n// struct B {}\nlet s = \"struct C\"\n"
        let lexed = SwiftLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["struct", "A", "let", "s"])
    }

    func testMultilineAndRawStringsAreBlanked() {
        let source = """
        let a = \"\"\"
          class Hidden {}
          \"\"\"
        let b = #"raw "quoted" \\(notCode)"#
        let c = ##"x"#y"##
        #if DEBUG
        #endif
        """
        let lexed = SwiftLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["let", "a", "let", "b", "let", "c", "if", "DEBUG", "endif"])
        XCTAssertEqual(lineOf("b", in: lexed), 4)
    }

    func testInterpolationStaysCode() {
        let source = #"let s = "total: \(format(Money.zero)) \("nested \(inner)")!" + tail"#
        let lexed = SwiftLexer.lex(source)
        assertSameShape(source, lexed)
        XCTAssertEqual(survivingWords(lexed), ["let", "s", "format", "Money", "zero", "inner", "tail"])
    }

    func testUnterminatedStringEndsAtTheLine() {
        let source = "let s = \"open\nstruct Next {}"
        let lexed = SwiftLexer.lex(source)
        XCTAssertEqual(survivingWords(lexed), ["let", "s", "struct", "Next"])
    }
}
