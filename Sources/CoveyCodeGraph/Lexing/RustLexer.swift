import Foundation

/// Blanks Rust comments and literals: `//`, nested `/* */`, strings (they may
/// span lines), raw strings `r#"…"#`, byte and C strings, char literals — and
/// keeps lifetimes (`'a`), which only look like the start of a char.
enum RustLexer {
    static func lex(_ text: String) -> LexedSource {
        var s = ByteScanner(text)
        while let b = s.peek() {
            if b == .slash && s.peek(1) == .slash {
                s.blankToLineEnd()
            } else if b == .slash && s.peek(1) == .star {
                s.blankBlockComment(nested: true)
            } else if b == .quote {
                s.blankQuoted(.quote, multiline: true)
            } else if b == .apostrophe {
                charOrLifetime(&s)
            } else if ByteScanner.isWord(b) {
                word(&s)
            } else {
                s.keep()
            }
        }
        return LexedSource(code: s.out)
    }

    /// An identifier, or the prefix of a byte/raw/C string or byte char.
    private static func word(_ s: inout ByteScanner) {
        guard !s.previousIsWord else { return s.keepWord() }
        let end = s.wordEnd
        let prefix = String(decoding: s.src[s.i..<end], as: UTF8.self)
        let next = end < s.src.count ? s.src[end] : 0
        switch (prefix, next) {
        case ("b", .apostrophe):
            s.blank()
            charOrLifetime(&s)
        case ("b", .quote), ("c", .quote):
            s.blank()
            s.blankQuoted(.quote, multiline: true)
        case ("r", .quote), ("r", .hash), ("br", .quote), ("br", .hash), ("cr", .quote), ("cr", .hash):
            var hashes = 0
            while end + hashes < s.src.count && s.src[end + hashes] == .hash { hashes += 1 }
            guard end + hashes < s.src.count, s.src[end + hashes] == .quote else {
                return s.keepWord()   // `r#ident`: a raw identifier
            }
            s.blank(prefix.utf8.count + hashes + 1)
            let closing = "\"" + String(repeating: "#", count: hashes)
            while s.peek() != nil && !s.matches(closing) { s.blank() }
            s.blank(closing.utf8.count)
        default:
            s.keepWord()
        }
    }

    /// `'x'`, `'\n'`, `'\u{1F600}'` are chars; `'a` (no closing quote right
    /// after one character) is a lifetime or loop label and stays code.
    private static func charOrLifetime(_ s: inout ByteScanner) {
        if s.peek(1) == .backslash {
            s.blank(3)
            while let c = s.peek(), c != .apostrophe, c != .newline { s.blank() }
            if s.peek() == .apostrophe { s.blank() }
            return
        }
        guard let lead = s.peek(1), lead != .newline else { return s.keep() }
        let length = ByteScanner.scalarLength(lead)
        if s.peek(1 + length) == .apostrophe {
            s.blank(length + 2)
        } else {
            s.keep()
        }
    }
}
