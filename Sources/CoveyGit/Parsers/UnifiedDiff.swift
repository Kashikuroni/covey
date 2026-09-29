import Foundation

public enum UnifiedDiff {
    /// Parses the diff of ONE file. File headers (`diff --git`, `index`,
    /// `---`/`+++`, mode lines) before the first hunk are skipped; inside a
    /// hunk every line is content, so `--- x` there is a removed `-- x`.
    ///
    /// Splits on UTF-8 byte 0x0A ('\n') to handle CRLF correctly; classifies
    /// lines by first byte to avoid Character-based prefix issues with combining marks.
    public static func parse(_ text: String) -> FileDiff {
        let data = text.data(using: .utf8) ?? Data()
        let lines = splitOnLF(data)

        var hunks: [Hunk] = []
        var isBinary = false
        var current: Hunk?
        var oldNumber = 0
        var newNumber = 0

        for lineData in lines {
            let line = String(decoding: lineData, as: UTF8.self)

            if line.hasPrefix("@@") {
                if let done = current { hunks.append(done) }
                current = nil
                guard let h = header(line) else { continue }
                current = Hunk(header: line, oldStart: h.oldStart, oldCount: h.oldCount,
                               newStart: h.newStart, newCount: h.newCount, lines: [])
                oldNumber = h.oldStart
                newNumber = h.newStart
                continue
            }
            guard current != nil else {
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" { isBinary = true }
                continue
            }

            // Classify by first byte, extract content as remaining bytes
            let bytes = Array(lineData)
            if bytes.isEmpty { continue }

            let firstByte = bytes[0]
            let contentBytes = bytes.dropFirst()
            var text = String(decoding: contentBytes, as: UTF8.self)
            // Strip exactly one trailing "\r" (byte 0x0D)
            if text.hasSuffix("\r") {
                text.removeLast()
            }

            if firstByte == 0x2B { // '+'
                current!.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber,
                                               text: text))
                newNumber += 1
            } else if firstByte == 0x2D { // '-'
                current!.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil,
                                               text: text))
                oldNumber += 1
            } else if firstByte == 0x20 { // ' ' (space)
                current!.lines.append(DiffLine(kind: .context, oldNumber: oldNumber,
                                               newNumber: newNumber, text: text))
                oldNumber += 1
                newNumber += 1
            } else if firstByte == 0x5C { // '\' (backslash, for "\ No newline...")
                // Skip "\ No newline at end of file" and similar
                continue
            } else if firstByte == 0x40 { // '@' (start of new hunk header, shouldn't happen)
                if let done = current { hunks.append(done) }
                current = nil
            } else if line.hasPrefix("diff --git") {
                if let done = current { hunks.append(done) }
                current = nil
            }
        }
        if let done = current { hunks.append(done) }
        return FileDiff(hunks: hunks, isBinary: isBinary)
    }

    /// Splits data on UTF-8 byte 0x0A ('\n'), keeping empty subsequences.
    /// Returns array of Data objects, each containing bytes between LF characters.
    private static func splitOnLF(_ data: Data) -> [Data] {
        var result: [Data] = []
        var current = Data()

        for byte in data {
            if byte == 0x0A { // '\n'
                result.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        result.append(current)
        return result
    }

    /// `@@ -a[,b] +c[,d] @@ …` — an omitted count means 1.
    static func header(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ token: Substring) -> (Int, Int)? {
            let numbers = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(numbers[0]) else { return nil }
            let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}
