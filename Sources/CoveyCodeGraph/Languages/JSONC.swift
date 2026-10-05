import Foundation

/// JSON with `//` and `/* */` comments and trailing commas, as `tsconfig.json`
/// allows. Cleaned up, then read by `JSONSerialization`.
enum JSONC {
    /// The top-level object, or nil when the text is not one.
    static func object(_ text: String) -> [String: Any]? {
        let cleaned = strip(Array(text.utf8))
        return (try? JSONSerialization.jsonObject(with: Data(cleaned))) as? [String: Any]
    }

    /// Drops comments, and a comma followed only by whitespace before `}` or `]`.
    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var pendingComma: Int?
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == .quote {
                out.append(b)
                i += 1
                while i < bytes.count {
                    let c = bytes[i]
                    out.append(c)
                    i += 1
                    if c == .backslash && i < bytes.count {
                        out.append(bytes[i])
                        i += 1
                    } else if c == .quote {
                        break
                    }
                }
                pendingComma = nil
            } else if b == .slash && i + 1 < bytes.count && bytes[i + 1] == .slash {
                while i < bytes.count && bytes[i] != .newline { i += 1 }
            } else if b == .slash && i + 1 < bytes.count && bytes[i + 1] == .star {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == .star && bytes[i + 1] == .slash) { i += 1 }
                i += 2
            } else if b == UInt8(ascii: ",") {
                pendingComma = out.count
                out.append(b)
                i += 1
            } else if b == .closeBrace || b == .closeBracket {
                if let comma = pendingComma { out[comma] = .space }
                pendingComma = nil
                out.append(b)
                i += 1
            } else {
                if !(b == .space || b == .tab || b == .newline || b == .carriageReturn) { pendingComma = nil }
                out.append(b)
                i += 1
            }
        }
        return out
    }
}
