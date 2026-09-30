import XCTest
@testable import CoveyCodeGraph

/// Identifiers that survive lexing, in source order.
func survivingWords(_ lexed: LexedSource) -> [String] {
    Tokenizer.tokens(lexed).filter { $0.kind == .word }.map(\.text)
}

/// The line of the first surviving token `word`.
func lineOf(_ word: String, in lexed: LexedSource) -> Int? {
    Tokenizer.tokens(lexed).first { $0.kind == .word && $0.text == word }?.line
}

/// Blanking never adds, drops or moves a byte, and never touches a newline.
func assertSameShape(_ source: String, _ lexed: LexedSource, file: StaticString = #filePath, line: UInt = #line) {
    let original = Array(source.utf8)
    XCTAssertEqual(lexed.code.count, original.count, "byte count", file: file, line: line)
    let newlines = original.indices.filter { original[$0] == .newline }
    XCTAssertEqual(lexed.code.indices.filter { lexed.code[$0] == .newline }, newlines,
                   "newline offsets", file: file, line: line)
}
