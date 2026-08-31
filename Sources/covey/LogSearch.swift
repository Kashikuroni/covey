import Foundation

/// One matching line from the app's log directory, as shown in the
/// log-search sheet.
struct LogLine: Equatable {
    let file: String      // file name only, no path
    let line: Int         // 1-based line number within the file
    let text: String
}

/// Paths of every `*.log` directly inside `dir`, newest-modified first.
/// Missing directory → empty (the sheet shows "no logs" rather than failing).
func logFiles(in dir: String) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
        return []
    }
    let paths = names.filter { $0.hasSuffix(".log") }
        .compactMap { name -> String? in
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue ? path : nil
        }
    // Newest-modified first; name as tiebreak.
    return paths.sorted { lhs, rhs in
        let l = (try? FileManager.default.attributesOfItem(
            atPath: lhs)[.modificationDate]) as? Date ?? .distantPast
        let r = (try? FileManager.default.attributesOfItem(
            atPath: rhs)[.modificationDate]) as? Date ?? .distantPast
        return l == r ? lhs < rhs : l > r
    }
}

/// Live-grep over preloaded file contents (Telescope-style): files in the
/// given order (newest first), lines within a file bottom-up so fresh entries
/// surface first. The query is a case-insensitive regex; an invalid pattern
/// degrades to a literal case-insensitive contains. An empty query lists the
/// tail of each file (no filter). Results are capped at `limit`, keeping the
/// newest.
/// Per-file line cap for the no-query browse view.
private let emptyQueryTail = 100

func searchLogs(files: [(name: String, content: String)],
                query: String,
                limit: Int = 500) -> [LogLine] {
    let matcher = query.isEmpty
        ? nil
        : (try? NSRegularExpression(pattern: query, options: [.caseInsensitive]))
            ?? (try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: query),
                options: [.caseInsensitive]))
    var hits: [LogLine] = []
    for (name, content) in files {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        // An unfiltered view would be dominated by one long file, so the
        // no-query browse shows at most the newest `emptyQueryTail` lines
        // per file instead.
        let slice: [(offset: Int, element: String.SubSequence)] = query.isEmpty
            ? Array(lines.enumerated().suffix(emptyQueryTail))
            : Array(lines.enumerated())
        for (offset, raw) in slice.reversed() {
            let text = String(raw)
            let matched: Bool
            if let matcher {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                matched = matcher.firstMatch(in: text, range: range) != nil
            } else {
                matched = true
            }
            guard matched else { continue }
            hits.append(LogLine(file: name, line: offset + 1, text: text))
            if hits.count == limit {
                // Full: the first file(s) in order (newest) already hold the cap.
                return hits
            }
        }
    }
    return hits
}

/// Reads a log file as UTF-8; unreadable files yield "" (the search simply
/// skips them — a locked or vanished log must not break the sheet).
func readLogFile(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// Case-insensitive substring filter for the file dropdown; empty query
/// keeps all names.
func filterLogNames(_ names: [String], query: String) -> [String] {
    guard !query.isEmpty else { return names }
    return names.filter { $0.range(of: query, options: .caseInsensitive) != nil }
}
