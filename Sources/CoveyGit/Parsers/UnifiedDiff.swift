import Foundation

public enum UnifiedDiff {
    /// Parses the diff of ONE file. File headers (`diff --git`, `index`,
    /// `---`/`+++`, mode lines) before the first hunk are skipped; inside a
    /// hunk every line is content, so `--- x` there is a removed `-- x`.
    ///
    /// Splits on UTF-8 byte 0x0A ('\n') to handle CRLF correctly; classifies
    /// lines by first byte to avoid Character-based prefix issues with combining marks.
    ///
    /// An empty line inside a hunk whose header counts are not yet used up is an
    /// empty CONTEXT line: `diff.suppressBlankEmpty` makes git print a blank
    /// context line as a bare "\n" with no leading space. Once the counts are
    /// exhausted an empty line is just the split artefact of the trailing newline.
    public static func parse(_ text: String) -> FileDiff {
        var hunks: [Hunk] = []
        var isBinary = false
        var current: Hunk?
        var oldNumber = 0
        var newNumber = 0
        var oldRemaining = 0
        var newRemaining = 0

        for bytes in Array(text.utf8).split(separator: 0x0A, omittingEmptySubsequences: false) {
            if bytes.starts(with: [0x40, 0x40]) { // "@@"
                if let done = current { hunks.append(done) }
                current = nil
                let line = String(decoding: bytes, as: UTF8.self)
                guard let h = header(line) else { continue }
                current = Hunk(header: line, oldStart: h.oldStart, oldCount: h.oldCount,
                               newStart: h.newStart, newCount: h.newCount, lines: [])
                oldNumber = h.oldStart
                newNumber = h.newStart
                oldRemaining = h.oldCount
                newRemaining = h.newCount
                continue
            }
            guard current != nil else {
                let line = String(decoding: bytes, as: UTF8.self)
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" { isBinary = true }
                continue
            }

            guard let firstByte = bytes.first else {
                if oldRemaining > 0 && newRemaining > 0 {
                    current!.lines.append(DiffLine(kind: .context, oldNumber: oldNumber,
                                                   newNumber: newNumber, text: ""))
                    oldNumber += 1
                    newNumber += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                }
                continue
            }

            // Classify by first byte, extract content as remaining bytes, and
            // strip exactly one trailing "\r" (byte 0x0D).
            var content = bytes.dropFirst()
            if content.last == 0x0D { content = content.dropLast() }
            let text = String(decoding: content, as: UTF8.self)

            if firstByte == 0x2B { // '+'
                current!.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber,
                                               text: text))
                newNumber += 1
                newRemaining -= 1
            } else if firstByte == 0x2D { // '-'
                current!.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil,
                                               text: text))
                oldNumber += 1
                oldRemaining -= 1
            } else if firstByte == 0x20 { // ' ' (space)
                current!.lines.append(DiffLine(kind: .context, oldNumber: oldNumber,
                                               newNumber: newNumber, text: text))
                oldNumber += 1
                newNumber += 1
                oldRemaining -= 1
                newRemaining -= 1
            } else if firstByte == 0x5C { // '\' (backslash, for "\ No newline...")
                // Skip "\ No newline at end of file" and similar
                continue
            } else if firstByte == 0x40 { // '@' (start of new hunk header, shouldn't happen)
                if let done = current { hunks.append(done) }
                current = nil
            } else if bytes.starts(with: Array("diff --git".utf8)) {
                if let done = current { hunks.append(done) }
                current = nil
            }
        }
        if let done = current { hunks.append(done) }
        return FileDiff(hunks: hunks, isBinary: isBinary)
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
