import Foundation

/// Blanks Python comments and strings: `#`, `'…'`, `"…"`, `'''…'''`, `"""…"""`
/// (docstrings included), with any `r/b/f/u` prefix.
enum PythonLexer {
    private static let prefixLetters = Set("rRbBfFuU".utf8)

    static func lex(_ text: String) -> LexedSource {
        var s = ByteScanner(text)
        while let b = s.peek() {
            if b == .hash {
                s.blankToLineEnd()
            } else if b == .quote || b == .apostrophe {
                string(&s)
            } else if ByteScanner.isWord(b) {
                let end = s.wordEnd
                let length = end - s.i
                let isPrefix = !s.previousIsWord && length <= 2
                    && s.src[s.i..<end].allSatisfy { prefixLetters.contains($0) }
                    && end < s.src.count && (s.src[end] == .quote || s.src[end] == .apostrophe)
                if isPrefix {
                    s.blank(length)
                    string(&s)
                } else {
                    s.keepWord()
                }
            } else {
                s.keep()
            }
        }
        return LexedSource(code: s.out)
    }

    /// A string at the cursor. Single-quoted ones end at an unescaped newline;
    /// a backslash (raw strings too) always takes the next byte with it.
    private static func string(_ s: inout ByteScanner) {
        guard let quote = s.peek() else { return }
        guard s.peek(1) == quote && s.peek(2) == quote else {
            s.blankQuoted(quote, multiline: false)
            return
        }
        s.blank(3)
        while let b = s.peek() {
            if b == .backslash {
                s.blank(2)
            } else if b == quote && s.peek(1) == quote && s.peek(2) == quote {
                s.blank(3)
                return
            } else {
                s.blank()
            }
        }
    }
}
