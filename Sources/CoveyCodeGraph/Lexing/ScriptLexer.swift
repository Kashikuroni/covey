import Foundation

/// Blanks TypeScript/JavaScript comments and literals: `//`, `/* */`, `'…'`,
/// `"…"`, template literals (code inside `${ … }` stays code) and regex
/// literals, recognised by the usual heuristic: a `/` where an operand is
/// expected starts a regex. Plain strings and substitution-free templates are
/// kept in `strings` — import specifiers are read from them.
enum ScriptLexer {
    /// A regex body longer than this is taken for division; bounds the
    /// look-ahead so a huge minified line stays linear.
    static let maxRegexLength = 1024

    private enum Mode {
        /// `braces` counts `{` opened inside a `${ … }`.
        case code(braces: Int)
        /// `start` is the backtick's offset; `plain` until a `${` shows up.
        case template(start: Int, plain: Bool)
    }

    /// After these words an operand is expected, so `/` starts a regex.
    private static let operandKeywords: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
        "throw", "case", "do", "else", "yield", "await",
    ]

    static func lex(_ text: String) -> LexedSource {
        var s = ByteScanner(text)
        var strings: [StringLiteral] = []
        var stack: [Mode] = [.code(braces: 0)]
        var operandExpected = true
        var afterLessThan = false   // `</` closes a JSX tag, never a regex
        while let b = s.peek() {
            switch stack[stack.count - 1] {
            case .template(let start, let plain):
                if b == .backslash {
                    s.blank(2)
                } else if b == .backtick {
                    if plain {
                        strings.append(StringLiteral(
                            offset: start, value: String(decoding: s.src[(start + 1)..<s.i], as: UTF8.self)))
                    }
                    s.blank()
                    stack.removeLast()
                    operandExpected = false
                } else if b == .dollar && s.peek(1) == .openBrace {
                    s.blank(2)
                    stack[stack.count - 1] = .template(start: start, plain: false)
                    stack.append(.code(braces: 0))
                    operandExpected = true
                } else {
                    s.blank()
                }
            case .code(let braces):
                if b == .slash && s.peek(1) == .slash {
                    s.blankToLineEnd()
                } else if b == .slash && s.peek(1) == .star {
                    s.blankBlockComment(nested: false)
                } else if b == .quote || b == .apostrophe {
                    let start = s.i
                    if let value = s.blankQuoted(b, multiline: false) {
                        strings.append(StringLiteral(offset: start, value: value))
                    }
                    operandExpected = false
                } else if b == .backtick {
                    stack.append(.template(start: s.i, plain: true))
                    s.blank()
                } else if b == .slash {
                    if operandExpected && !afterLessThan && blankRegex(&s) {
                        operandExpected = false
                    } else {
                        s.keep()
                        operandExpected = true
                    }
                } else if b == .openBrace {
                    s.keep()
                    stack[stack.count - 1] = .code(braces: braces + 1)
                    operandExpected = true
                } else if b == .closeBrace {
                    if braces == 0 && stack.count > 1 {
                        s.blank()   // closes `${`
                        stack.removeLast()
                    } else {
                        s.keep()
                        stack[stack.count - 1] = .code(braces: max(0, braces - 1))
                        operandExpected = false
                    }
                } else if ByteScanner.isWord(b) {
                    let end = s.wordEnd
                    operandExpected = operandKeywords.contains(String(decoding: s.src[s.i..<end], as: UTF8.self))
                    s.keepWord()
                } else if b == .space || b == .tab || b == .newline || b == .carriageReturn {
                    s.keep()
                    continue
                } else {
                    operandExpected = !(b == .closeParen || b == .closeBracket)
                    s.keep()
                }
                afterLessThan = b == UInt8(ascii: "<")
            }
        }
        strings.sort { $0.offset < $1.offset }
        return LexedSource(code: s.out, strings: strings)
    }

    /// Blanks `/body/flags` when the body closes on this line; otherwise
    /// leaves everything alone and returns false (it was division).
    private static func blankRegex(_ s: inout ByteScanner) -> Bool {
        var k = s.i + 1
        var inClass = false
        let limit = min(s.src.count, s.i + maxRegexLength)
        while k < limit {
            let c = s.src[k]
            if c == .newline { return false }
            if c == .backslash {
                if k + 1 < s.src.count && s.src[k + 1] == .newline { return false }
                k += 2
                continue
            }
            if c == .openBracket {
                inClass = true
            } else if c == .closeBracket {
                inClass = false
            } else if c == .slash && !inClass {
                break
            }
            k += 1
        }
        guard k < limit else { return false }
        k += 1
        while k < s.src.count && ByteScanner.isWord(s.src[k]) { k += 1 }
        s.blank(k - s.i)
        return true
    }
}
