import Foundation

/// A source file with comments and string literals blanked to spaces. Every
/// blanked byte becomes a space except `\n` and `\r`, so line numbers and
/// byte columns match the original text.
struct LexedSource {
    var code: [UInt8]
    /// String literals kept for later parsing (TS/JS import specifiers),
    /// sorted by the byte offset of their opening quote.
    var strings: [StringLiteral] = []

    /// The blanked text, for tests and debugging.
    var text: String { String(decoding: code, as: UTF8.self) }
}

struct StringLiteral: Equatable {
    /// Byte offset of the opening quote.
    var offset: Int
    /// The raw text between the quotes (escapes not decoded).
    var value: String
}

extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let slash = UInt8(ascii: "/")
    static let backslash = UInt8(ascii: "\\")
    static let star = UInt8(ascii: "*")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let backtick = UInt8(ascii: "`")
    static let hash = UInt8(ascii: "#")
    static let dollar = UInt8(ascii: "$")
    static let colon = UInt8(ascii: ":")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
}

/// A cursor over a file's UTF-8 bytes. Code is copied through untouched;
/// the lexers call `blank` on comments and strings.
struct ByteScanner {
    let src: [UInt8]
    var out: [UInt8]
    var i = 0

    init(_ text: String) {
        src = Array(text.utf8)
        out = src
    }

    /// Letters, digits, `_`, `$` and every non-ASCII byte (identifiers may be Unicode).
    static func isWord(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
            || b == 0x5F || b == .dollar || b >= 0x80
    }

    /// Byte length of the UTF-8 scalar that starts with `lead`.
    static func scalarLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xF0...: return 4
        case 0xE0...: return 3
        case 0xC0...: return 2
        default: return 1
        }
    }

    func peek(_ offset: Int = 0) -> UInt8? {
        let k = i + offset
        return k < src.count ? src[k] : nil
    }

    var previousIsWord: Bool { i > 0 && Self.isWord(src[i - 1]) }

    /// End offset of the identifier that starts at the cursor.
    var wordEnd: Int {
        var k = i
        while k < src.count && Self.isWord(src[k]) { k += 1 }
        return k
    }

    /// Leaves `count` bytes as code.
    mutating func keep(_ count: Int = 1) {
        i = min(i + count, src.count)
    }

    mutating func keepWord() {
        i = wordEnd
    }

    /// Blanks `count` bytes (newlines survive) and moves past them.
    mutating func blank(_ count: Int = 1) {
        for _ in 0..<count where i < src.count {
            if src[i] != .newline && src[i] != .carriageReturn { out[i] = .space }
            i += 1
        }
    }

    /// Blanks up to, not including, the next newline.
    mutating func blankToLineEnd() {
        while let b = peek(), b != .newline { blank() }
    }

    /// Blanks a `/* … */` comment. With `nested`, inner `/*` must be closed
    /// too (Rust, Swift).
    mutating func blankBlockComment(nested: Bool) {
        blank(2)
        var depth = 1
        while let b = peek() {
            if nested && b == .slash && peek(1) == .star {
                depth += 1
                blank(2)
            } else if b == .star && peek(1) == .slash {
                blank(2)
                depth -= 1
                if depth == 0 { return }
            } else {
                blank()
            }
        }
    }

    /// Blanks a string that opens at the cursor with `quote`; a backslash
    /// escapes the next byte. A single-line string that meets a newline stops
    /// there (unterminated). Returns the raw content when the string closed.
    @discardableResult
    mutating func blankQuoted(_ quote: UInt8, multiline: Bool) -> String? {
        blank()
        let start = i
        while let b = peek() {
            if b == .backslash {
                blank(2)
            } else if b == quote {
                let value = String(decoding: src[start..<i], as: UTF8.self)
                blank()
                return value
            } else if b == .newline && !multiline {
                return nil
            } else {
                blank()
            }
        }
        return nil
    }

    /// True when the bytes at the cursor are `ascii`.
    func matches(_ ascii: String, at offset: Int = 0) -> Bool {
        var k = i + offset
        for b in ascii.utf8 {
            guard k < src.count, src[k] == b else { return false }
            k += 1
        }
        return true
    }
}
