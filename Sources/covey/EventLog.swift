import CoveyKit
import Foundation

/// Permanent history of user-facing notices: every toast and every review
/// banner lands as one NDJSON line in `events.log` inside `LogPaths.directory`,
/// so an error that flashed on screen can still be found (and copied) later
/// through "Search App Logs". Timestamps are absolute (epoch ms) — the file
/// spans runs, unlike `PaneLayoutLog`'s per-run clock.
///
/// The file is cut back under 1 MB on write when it grows past that; the tail
/// (newest lines) survives, the head is dropped.
enum EventLog {
    static let file = "events.log"
    static let cap = 1_000_000

    /// Injectable for tests; production writes to `directory`/file.
    nonisolated(unsafe) static var emit: (_ kind: String, _ message: String) -> Void =
        EventLog.write
    nonisolated(unsafe) static var directory: String = LogPaths.directory

    private static let queue = DispatchQueue(label: "covey.eventlog")
    private static var handle: FileHandle?

    static func note(_ kind: String, _ message: String) {
        emit(kind, message)
    }

    /// Appends one event, trimming the file to its tail first if it is over
    /// the cap. Runs on the serial queue; the handle is reused across writes.
    static func write(kind: String, message: String) {
        let line = "{\"t\":\(Int(Date().timeIntervalSince1970 * 1000)),"
            + "\"kind\":\"\(sanitize(kind))\","
            + "\"msg\":\"\(sanitize(message))\"}\n"
        queue.async {
            trimIfNeeded()
            if handle == nil {
                // createFile truncates, so an existing (possibly just
                // trimmed) file is opened for appending, not recreated.
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                handle = FileHandle(forWritingAtPath: path)
                handle?.seekToEndOfFile()
            }
            handle?.write(Data(line.utf8))
        }
    }

    /// Test seam: drains the write queue and forgets the open handle.
    static func closeForTesting() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    private static var path: String { directory + "/" + file }

    /// Over the cap → keep the newest half, cut at a line boundary, rewrite.
    private static func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: path)[.size]) as? Int, size > cap else { return }
        try? handle?.close()
        handle = nil
        guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let cut = data.count - cap / 2
        if let boundary = data[(cut...)].firstIndex(of: UInt8(ascii: "\n")) {
            data.removeSubrange(data.startIndex...boundary)
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Quotes, backslashes and control characters would break the one-event-
    /// one-line rule or the JSON — flattened to `·` (same as PaneLayoutLog).
    private static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.map {
            ($0 == "\"" || $0 == "\\" || $0.value < 0x20) ? "·" : Character($0)
        })
    }
}
