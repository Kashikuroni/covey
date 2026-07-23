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

    private func safeKey(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
    private func path(_ key: String) -> String { "\(root)/\(safeKey(key)).ndjson" }
    /// Sidecar holding the source-file byte offset already folded into this
    /// session's trace, so a daemon restart resumes instead of re-reading (and
    /// re-appending) the whole transcript.
    private func cursorPath(_ key: String) -> String { "\(root)/\(safeKey(key)).cursor" }

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

    /// Events with `seq >= sinceSeq`. `limit` keeps only the newest `limit`
    /// of them — the panel and the subscribe backlog never need the whole
    /// history, and reading it wholesale blocks the IPC queue.
    public func read(sessionKey: String, sinceSeq: Int, limit: Int? = nil) -> [TraceEvent] {
        queue.sync {
            guard let data = FileManager.default.contents(atPath: path(sessionKey)) else { return [] }
            var framer = LineFramer()
            let lines = (try? framer.feed([UInt8](data))) ?? []
            let matched = lines.compactMap { try? NDJSON.decoder.decode(TraceEvent.self, from: Data($0)) }
                .filter { $0.seq >= sinceSeq }
            if let limit, matched.count > limit { return Array(matched.suffix(limit)) }
            return matched
        }
    }

    public func lastSeq(sessionKey: String) -> Int {
        read(sessionKey: sessionKey, sinceSeq: 0).last?.seq ?? -1
    }

    /// The persisted source byte offset for a session, or nil if none is
    /// recorded (a fresh session, or a pre-cursor store to be migrated).
    public func loadOffset(sessionKey: String) -> UInt64? {
        queue.sync {
            guard let text = try? String(contentsOfFile: cursorPath(sessionKey), encoding: .utf8)
            else { return nil }
            return UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func saveOffset(sessionKey: String, offset: UInt64) {
        queue.sync {
            try? "\(offset)".write(toFile: cursorPath(sessionKey), atomically: true, encoding: .utf8)
        }
    }

    /// Drop a session's trace and cursor — used to migrate a pre-cursor
    /// (possibly duplicated) store before a clean re-read.
    public func reset(sessionKey: String) {
        queue.sync {
            try? FileManager.default.removeItem(atPath: path(sessionKey))
            try? FileManager.default.removeItem(atPath: cursorPath(sessionKey))
        }
    }

    public func totalBytes() -> Int {
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return names.filter { $0.hasSuffix(".ndjson") }.reduce(0) { sum, name in
                let attrs = try? FileManager.default.attributesOfItem(atPath: "\(root)/\(name)")
                return sum + ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
            }
        }
    }

    public func prune() {
        let cutoff = now().addingTimeInterval(-retention)
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names where name.hasSuffix(".ndjson") {
                let p = "\(root)/\(name)"
                guard let data = FileManager.default.contents(atPath: p) else { continue }
                var framer = LineFramer()
                let lines = (try? framer.feed([UInt8](data))) ?? []
                let newest = lines.compactMap {
                    try? NDJSON.decoder.decode(TraceEvent.self, from: Data($0)) }
                    .map(\.timestamp).max()
                if let newest, newest < cutoff { try? FileManager.default.removeItem(atPath: p) }
            }
        }
    }
}
