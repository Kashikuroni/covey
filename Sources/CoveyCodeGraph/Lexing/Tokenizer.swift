import Foundation

/// One token of blanked code.
struct Token: Equatable {
    enum Kind: Equatable {
        /// An identifier or number.
        case word
        /// One ASCII punctuation byte, or `::`.
        case punct
        /// A kept string literal (`LexedSource.strings`); `text` is its content.
        case string
    }

    var kind: Kind
    var text: String
    /// 1-based.
    var line: Int
    /// 0-based byte offset within the line.
    var column: Int

    func isPunct(_ p: String) -> Bool { kind == .punct && text == p }
    func isWord(_ w: String) -> Bool { kind == .word && text == w }
}

enum Tokenizer {
    /// Splits blanked code into words and punctuation, and puts the kept
    /// string literals back as `.string` tokens where they stood. Lines are
    /// counted by `\n` only, so CRLF files number the same as LF files.
    static func tokens(_ lexed: LexedSource) -> [Token] {
        let code = lexed.code
        var tokens: [Token] = []
        var line = 1
        var lineStart = 0
        var nextString = 0
        var i = 0
        while i < code.count {
            while nextString < lexed.strings.count && lexed.strings[nextString].offset < i {
                nextString += 1
            }
            if nextString < lexed.strings.count && lexed.strings[nextString].offset == i {
                tokens.append(Token(kind: .string, text: lexed.strings[nextString].value,
                                    line: line, column: i - lineStart))
                nextString += 1
            }
            let b = code[i]
            if b == .newline {
                line += 1
                lineStart = i + 1
                i += 1
            } else if b == .space || b == .tab || b == .carriageReturn || b == 0x0B || b == 0x0C {
                i += 1
            } else if ByteScanner.isWord(b) {
                let start = i
                while i < code.count && ByteScanner.isWord(code[i]) { i += 1 }
                tokens.append(Token(kind: .word, text: String(decoding: code[start..<i], as: UTF8.self),
                                    line: line, column: start - lineStart))
            } else if b == .colon && i + 1 < code.count && code[i + 1] == .colon {
                tokens.append(Token(kind: .punct, text: "::", line: line, column: i - lineStart))
                i += 2
            } else {
                tokens.append(Token(kind: .punct, text: String(UnicodeScalar(b)),
                                    line: line, column: i - lineStart))
                i += 1
            }
        }
        return tokens
    }

    /// Every identifier (not numbers) → the lines it appears on, ascending.
    static func wordLines(_ tokens: [Token]) -> [String: [Int]] {
        var lines: [String: [Int]] = [:]
        for token in tokens where token.kind == .word {
            guard let first = token.text.utf8.first, !(first >= 0x30 && first <= 0x39) else { continue }
            if lines[token.text]?.last != token.line {
                lines[token.text, default: []].append(token.line)
            }
        }
        return lines
    }
}
