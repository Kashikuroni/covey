import Foundation

/// Polls each claude session's transcript for the model id of the last
/// assistant message and reports changes. Same cadence pattern as GitMonitor.
public final class ModelMonitor {
    public var onModelChanged: ((String, String) -> Void)?

    public typealias Entry = (name: String, cwd: String, resumeCmd: String?)

    private let snapshot: () -> [Entry]
    private let projectsRoot: String
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.model")
    private var timer: DispatchSourceTimer?
    private var models: [String: String] = [:]      // name -> model id
    private var marks: [String: FileMark] = [:]     // name -> last transcript stat

    private struct FileMark: Equatable {
        var size: UInt64
        var mtime: Date
    }

    public init(interval: TimeInterval = 5,
                projectsRoot: String = NSHomeDirectory() + "/.claude/projects",
                snapshot: @escaping () -> [Entry]) {
        self.interval = interval
        self.projectsRoot = projectsRoot
        self.snapshot = snapshot
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // First pass immediately: cards should not wait out the interval
        // after a daemon start.
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass; tests call this directly.
    public func tick() {
        queue.sync { tickBody() }
    }

    /// Snapshot of the known models for the `list` payload.
    public func current() -> [String: String] {
        queue.sync { models }
    }

    /// Read one session now — create/restart of a resumed session call this
    /// so an existing transcript gets its badge without waiting out the interval.
    public func poke(name: String, cwd: String, resumeCmd: String?) {
        queue.async { [weak self] in
            self?.read(name: name, cwd: cwd, resumeCmd: resumeCmd)
        }
    }

    private func tickBody() {
        var seen = Set<String>()
        for entry in snapshot() {
            seen.insert(entry.name)
            read(name: entry.name, cwd: entry.cwd, resumeCmd: entry.resumeCmd)
        }
        // Wholesale filtering prunes removed sessions.
        models = models.filter { seen.contains($0.key) }
        marks = marks.filter { seen.contains($0.key) }
    }

    private func read(name: String, cwd: String, resumeCmd: String?) {
        guard let uuid = ClaudeTranscript.sessionUUID(resumeCmd: resumeCmd) else { return }
        let path = ClaudeTranscript.path(projectsRoot: projectsRoot, cwd: cwd, uuid: uuid)
        // No transcript yet (claude before its first message) — keep checking.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return }
        let mark = FileMark(size: size, mtime: mtime)
        if marks[name] == mark { return }       // unchanged since the last read
        marks[name] = mark
        // A tail with no valid assistant line (tool-result burst) keeps the
        // previous reading instead of clobbering it.
        guard let tail = ClaudeTranscript.readTail(path: path),
              let model = ClaudeTranscript.lastAssistantModel(tail: tail) else { return }
        if models[name] != model {
            models[name] = model
            onModelChanged?(name, model)
        }
    }
}
