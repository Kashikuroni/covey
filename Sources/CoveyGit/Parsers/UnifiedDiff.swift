import Foundation

public enum UnifiedDiff {
    /// Parses the diff of ONE file. File headers (`diff --git`, `index`,
    /// `---`/`+++`, mode lines) before the first hunk are skipped; inside a
    /// hunk every line is content, so `--- x` there is a removed `-- x`.
    public static func parse(_ text: String) -> FileDiff {
        var hunks: [Hunk] = []
        var isBinary = false
        var current: Hunk?
        var oldNumber = 0
        var newNumber = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
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
            if line.hasPrefix("+") {
                current!.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber,
                                               text: String(line.dropFirst())))
                newNumber += 1
            } else if line.hasPrefix("-") {
                current!.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil,
                                               text: String(line.dropFirst())))
                oldNumber += 1
            } else if line.hasPrefix(" ") {
                current!.lines.append(DiffLine(kind: .context, oldNumber: oldNumber,
                                               newNumber: newNumber, text: String(line.dropFirst())))
                oldNumber += 1
                newNumber += 1
            } else if line.hasPrefix("diff --git") {
                hunks.append(current!)
                current = nil
            }
            // "\ No newline at end of file" and the trailing empty split carry no row.
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
