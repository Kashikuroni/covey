import AppKit
import Foundation

/// TEMPORARY diagnostic for issue #2 ("agent pane renders as a 2-column
/// strip"). SwiftTerm floors its grid at 2 columns for any frame narrower than
/// ~30pt, so the strip means the pane view was laid out degenerately — but the
/// layout pass that does it has not been reproducible in a test window. This
/// records every pane layout so the culprit can be read off a real run.
///
/// Writes NDJSON to ~/Library/Logs/Covey/pane-layout.log. Delete this file and
/// its call sites once the source is identified.
enum PaneLayoutLog {
    static let path: String = {
        let dir = NSHomeDirectory() + "/Library/Logs/Covey"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir + "/pane-layout.log"
    }()

    private static let queue = DispatchQueue(label: "covey.panelayoutlog")
    private static var handle: FileHandle?
    private static let start = Date()

    /// Appends one event. `fields` are flattened into the line as-is.
    static func note(_ event: String, _ fields: [(String, Any)]) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        var line = "{\"t\":\(ms),\"e\":\"\(event)\""
        for (k, v) in fields {
            if let s = v as? String {
                line += ",\"\(k)\":\"\(s)\""
            } else if let d = v as? CGFloat {
                line += ",\"\(k)\":\(String(format: "%.1f", d))"
            } else {
                line += ",\"\(k)\":\(v)"
            }
        }
        line += "}\n"
        queue.async {
            if handle == nil {
                FileManager.default.createFile(atPath: path, contents: nil)
                handle = FileHandle(forWritingAtPath: path)
                handle?.seekToEndOfFile()
            }
            handle?.write(Data(line.utf8))
        }
    }

    /// Makes terminal content safe to embed in the JSON line.
    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.map {
            ($0 == "\"" || $0 == "\\" || $0.value < 0x20) ? "·" : Character($0)
        })
    }

    /// The view's ancestry widths — identifies WHICH container collapsed.
    static func ancestry(_ view: NSView) -> String {
        var widths: [String] = []
        var v: NSView? = view.superview
        var depth = 0
        while let cur = v, depth < 6 {
            widths.append(String(format: "%.0f", cur.frame.width))
            v = cur.superview
            depth += 1
        }
        return widths.joined(separator: "/")
    }
}
