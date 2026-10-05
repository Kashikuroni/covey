import Foundation
import CryptoKit
import CoveyGit

/// Review records at `<root>/<id>.json` plus `<root>/index.json` (worktree →
/// last comparison). Saves are debounced and atomic, like `StateStore`; the
/// repository itself is never written to.
final class ReviewStore: @unchecked Sendable {
    static let shared = ReviewStore(root: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".covey/reviews").path)

    struct Loaded {
        var record: ReviewRecord
        /// The file on disk was unreadable and was set aside.
        var recovered: Bool
    }

    private let root: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "covey.reviews")
    private var timer: DispatchSourceTimer?
    private var pending: [String: ReviewRecord] = [:]
    private var _writeCount = 0

    init(root: String, debounce: TimeInterval = 0.5) {
        self.root = URL(fileURLWithPath: root)
        self.debounce = debounce
    }

    /// First 16 hex digits of sha256(realpath(worktree) + NUL + comparison key).
    static func recordID(worktree: String, comparison: GitComparison) -> String {
        let key = canonical(worktree) + "\u{0}" + comparison.storageKey
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func recordPath(id: String) -> String {
        root.appendingPathComponent("\(id).json").path
    }

    func load(worktree: String, comparison: GitComparison) -> Loaded {
        let id = Self.recordID(worktree: worktree, comparison: comparison)
        if let queued = queue.sync(execute: { pending[id] }) {
            return Loaded(record: queued, recovered: false)
        }
        let fresh = ReviewRecord(worktree: worktree, comparison: comparison)
        let url = URL(fileURLWithPath: recordPath(id: id))
        guard let data = try? Data(contentsOf: url) else { return Loaded(record: fresh, recovered: false) }
        do {
            return Loaded(record: try JSONDecoder().decode(ReviewRecord.self, from: data), recovered: false)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(
                at: url, to: root.appendingPathComponent("\(id).corrupt-\(stamp).json"))
            return Loaded(record: fresh, recovered: true)
        }
    }

    func save(_ record: ReviewRecord) {
        let id = Self.recordID(worktree: record.worktree, comparison: record.comparison)
        queue.async { [weak self] in
            guard let self else { return }
            self.pending[id] = record
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.debounce)
            t.setEventHandler { [weak self] in self?.writePending() }
            self.timer = t
            t.resume()
        }
    }

    func flush() {
        queue.sync {
            timer?.cancel()
            timer = nil
            writePending()
        }
    }

    var writeCount: Int { queue.sync { _writeCount } }

    func lastComparison(worktree: String) -> GitComparison? {
        readIndex()[Self.canonical(worktree)]
    }

    func setLastComparison(_ comparison: GitComparison, worktree: String) {
        queue.sync {
            var index = readIndex()
            index[Self.canonical(worktree)] = comparison
            write(index, to: root.appendingPathComponent("index.json"))
        }
    }

    // MARK: - private

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func readIndex() -> [String: GitComparison] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode([String: GitComparison].self, from: data)
        else { return [:] }
        return index
    }

    /// On `queue`.
    private func writePending() {
        timer = nil
        let records = pending
        pending = [:]
        for (id, record) in records {
            if write(record, to: URL(fileURLWithPath: recordPath(id: id))) { _writeCount += 1 }
        }
    }

    @discardableResult
    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            return false   // best-effort, like StateStore: a failed write must not crash the UI
        }
    }
}
