import Foundation

/// Blanks Swift comments and literals: `//`, nested `/* */`, `"…"`, `"""…"""`
/// and raw `#"…"#` strings. Code inside `\( … )` interpolation stays code.
enum SwiftLexer {
    private enum Mode {
        /// `parens` counts `(` opened inside an interpolation.
        case code(parens: Int)
        case string(multiline: Bool)
    }

    static func lex(_ text: String) -> LexedSource {
        var s = ByteScanner(text)
        var stack: [Mode] = [.code(parens: 0)]
        while let b = s.peek() {
            switch stack[stack.count - 1] {
            case .string(let multiline):
                if b == .backslash && s.peek(1) == .openParen {
                    s.blank(2)
                    stack.append(.code(parens: 0))
                } else if b == .backslash {
                    s.blank(2)
                } else if multiline && s.matches("\"\"\"") {
                    s.blank(3)
                    stack.removeLast()
                } else if !multiline && b == .quote {
                    s.blank()
                    stack.removeLast()
                } else if !multiline && b == .newline {
                    stack.removeLast()   // unterminated: the line ends it
                } else {
                    s.blank()
                }
            case .code(let parens):
                if b == .slash && s.peek(1) == .slash {
                    s.blankToLineEnd()
                } else if b == .slash && s.peek(1) == .star {
                    s.blankBlockComment(nested: true)
                } else if b == .quote {
                    let multiline = s.matches("\"\"\"")
                    s.blank(multiline ? 3 : 1)
                    stack.append(.string(multiline: multiline))
                } else if b == .hash {
                    rawString(&s)
                } else if b == .openParen {
                    s.keep()
                    stack[stack.count - 1] = .code(parens: parens + 1)
                } else if b == .closeParen {
                    if parens == 0 && stack.count > 1 {
                        s.blank()   // closes `\(`
                        stack.removeLast()
                    } else {
                        s.keep()
                        stack[stack.count - 1] = .code(parens: max(0, parens - 1))
                    }
                } else if ByteScanner.isWord(b) {
                    s.keepWord()
                } else {
                    s.keep()
                }
            }
        }
        return LexedSource(code: s.out)
    }

    /// `#"…"#`, `##"…"##`, `#"""…"""#`; any other `#` (`#if`, `#selector`) is code.
    private static func rawString(_ s: inout ByteScanner) {
        var hashes = 0
        while s.peek(hashes) == .hash { hashes += 1 }
        guard s.peek(hashes) == .quote else { return s.keep(hashes) }
        let multiline = s.matches("\"\"\"", at: hashes)
        let quotes = multiline ? "\"\"\"" : "\""
        let closing = quotes + String(repeating: "#", count: hashes)
        s.blank(hashes + quotes.utf8.count)
        while let b = s.peek(), !s.matches(closing) {
            if b == .newline && !multiline { return }
            s.blank()
        }
        s.blank(closing.utf8.count)
    }
}
