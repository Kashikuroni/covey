import Foundation
import CoveyKit

/// Per-session NDJSON trace persistence under `root`. One file per sessionKey
/// (the source transcript id). Thread-safe via a serial queue.
public final class TraceStore {
    private let root: String
    private let retention: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "covey.trace.store")

    public init(root: String = NSHomeDirectory() + "/.covey/traces",
                retention: TimeInterval = 7 * 24 * 3600,
                now: @escaping () -> Date = Date.init) {
        self.root = root; self.retention = retention; self.now = now
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private func path(_ key: String) -> String {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return "\(root)/\(safe).ndjson"
    }

    public func append(sessionKey: String, events: [TraceEvent]) {
        guard !events.isEmpty else { return }
        queue.sync {
            var bytes: [UInt8] = []
            for e in events { if let line = try? NDJSON.encodeLine(e) { bytes += line } }
            let p = path(sessionKey)
            if let fh = FileHandle(forWritingAtPath: p) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd(); try? fh.write(contentsOf: Data(bytes))
            } else {
                FileManager.default.createFile(atPath: p, contents: Data(bytes))
            }
        }
    }

    public func read(sessionKey: String, sinceSeq: Int) -> [TraceEvent] {
        queue.sync {
            guard let data = FileManager.default.contents(atPath: path(sessionKey)) else { return [] }
            var framer = LineFramer()
            let lines = (try? framer.feed([UInt8](data))) ?? []
            return lines.compactMap { try? NDJSON.decoder.decode(TraceEvent.self, from: Data($0)) }
                .filter { $0.seq >= sinceSeq }
        }
    }

    public func lastSeq(sessionKey: String) -> Int {
        read(sessionKey: sessionKey, sinceSeq: 0).last?.seq ?? -1
    }
}
