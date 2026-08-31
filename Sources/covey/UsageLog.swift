import Foundation

/// Persistent diagnostic log for the usage/limit subsystem (Claude, Codex,
/// GLM). NDJSON, one event per line, appended to
/// ~/Library/Logs/Covey/usage.log and rotated at 1 MB (one `.1` generation
/// kept). Records every poll outcome, RPC error, and parse failure so a
/// stalled chip can be diagnosed after the fact. Never logs tokens or key
/// material — only endpoints, status codes, and short body excerpts.
enum UsageLog {
    static let path: String = {
        let dir = NSHomeDirectory() + "/Library/Logs/Covey"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir + "/usage.log"
    }()

    private static let queue = DispatchQueue(label: "covey.usagelog")
    private static var handle: FileHandle?

    private static let maxBytes = 1_000_000

    /// Appends one event. `fields` are flattened into the line as-is.
    static func note(_ event: String, _ fields: [(String, Any)]) {
        let ms = ISO8601DateFormatter().string(from: Date())
        var line = "{\"t\":\"\(ms)\",\"e\":\"\(event)\""
        for (k, v) in fields {
            if let s = v as? String {
                line += ",\"\(k)\":\"\(sanitize(s))\""
            } else if let d = v as? Double {
                line += ",\"\(k)\":\(String(format: "%.1f", d))"
            } else {
                line += ",\"\(k)\":\(v)"
            }
        }
        line += "}\n"
        queue.async {
            rotateIfNeeded()
            if handle == nil {
                FileManager.default.createFile(atPath: path, contents: nil)
                handle = FileHandle(forWritingAtPath: path)
                handle?.seekToEndOfFile()
            }
            handle?.write(Data(line.utf8))
        }
    }

    /// First 200 chars of a response body — enough to see an API shape change,
    /// short enough not to balloon the log.
    static func excerpt(_ data: Data) -> String {
        let s = String(decoding: data.prefix(200), as: UTF8.self)
        return s.count < 200 ? s : s + "…"
    }

    private static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.map {
            ($0 == "\"" || $0 == "\\" || $0.value < 0x20) ? "·" : Character($0)
        })
    }

    /// Keeps usage.log under maxBytes; the overflow becomes usage.log.1 and
    /// the log restarts empty. Checked before each write, off the hot path.
    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: path)[.size]) as? Int, size > maxBytes else { return }
        handle?.closeFile(); handle = nil
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
}
