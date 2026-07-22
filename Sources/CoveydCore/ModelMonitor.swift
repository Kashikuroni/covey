import Foundation

/// Polls Claude transcripts and Codex rollouts for each session's current
/// model id and reports changes. Same cadence pattern as GitMonitor.
public final class ModelMonitor {
    public var onModelChanged: ((String, String) -> Void)?

    public typealias Entry = (
        name: String, cwd: String, agent: String, created: Int64, resumeCmd: String?
    )

    private let snapshot: () -> [Entry]
    private let projectsRoot: String
    private let codexSessionsRoot: String
    private let codexConfigPath: String
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "covey.model")
    private var timer: DispatchSourceTimer?
    private var models: [String: String] = [:]      // name -> model id
    private var marks: [String: FileMark] = [:]     // name -> last transcript stat
    private var codexPaths: [String: String] = [:]  // name -> assigned rollout

    private struct FileMark: Equatable {
        var size: UInt64
        var mtime: Date
    }

    public init(interval: TimeInterval = 5,
                projectsRoot: String = NSHomeDirectory() + "/.claude/projects",
                codexSessionsRoot: String = NSHomeDirectory() + "/.codex/sessions",
                codexConfigPath: String = NSHomeDirectory() + "/.codex/config.toml",
                snapshot: @escaping () -> [Entry]) {
        self.interval = interval
        self.projectsRoot = projectsRoot
        self.codexSessionsRoot = codexSessionsRoot
        self.codexConfigPath = codexConfigPath
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

    /// Read one session now so its existing transcript/rollout or configured
    /// fallback can populate the badge without waiting out the interval.
    public func poke(name: String, cwd: String, agent: String, created: Int64,
                     resumeCmd: String?) {
        queue.async { [weak self] in
            self?.read(entry: (name, cwd, agent, created, resumeCmd))
        }
    }

    private func tickBody() {
        var seen = Set<String>()
        for entry in snapshot() {
            seen.insert(entry.name)
            read(entry: entry)
        }
        // Wholesale filtering prunes removed sessions.
        models = models.filter { seen.contains($0.key) }
        marks = marks.filter { seen.contains($0.key) }
        codexPaths = codexPaths.filter { seen.contains($0.key) }
    }

    private func read(entry: Entry) {
        if let uuid = ClaudeTranscript.sessionUUID(resumeCmd: entry.resumeCmd) {
            readClaude(name: entry.name, cwd: entry.cwd, uuid: uuid)
        } else if CodexTranscript.isCodexAgent(entry.agent) {
            readCodex(entry: entry)
        }
    }

    private func readClaude(name: String, cwd: String, uuid: String) {
        let path = ClaudeTranscript.path(projectsRoot: projectsRoot, cwd: cwd, uuid: uuid)
        guard changed(path: path, name: name),
              let tail = ClaudeTranscript.readTail(path: path),
              let model = ClaudeTranscript.lastAssistantModel(tail: tail) else { return }
        emit(name: name, model: model)
    }

    private func readCodex(entry: Entry) {
        if models[entry.name] == nil {
            let fallback = CodexTranscript.commandModel(entry.agent)
                ?? CodexTranscript.configuredModel(path: codexConfigPath)
            if let fallback { emit(name: entry.name, model: fallback) }
        }
        if codexPaths[entry.name] == nil {
            codexPaths[entry.name] = discoverCodexPath(entry: entry)
        }
        guard let path = codexPaths[entry.name],
              changed(path: path, name: entry.name),
              let tail = CodexTranscript.readTail(path: path),
              let model = CodexTranscript.lastTurnModel(tail: tail) else { return }
        emit(name: entry.name, model: model)
    }

    private func discoverCodexPath(entry: Entry) -> String? {
        let expectedCwd = URL(fileURLWithPath: entry.cwd).standardizedFileURL.path
        let assigned = Set(codexPaths.values)
        return CodexTranscript.rolloutPaths(sessionsRoot: codexSessionsRoot,
                                            created: entry.created)
            .filter { !assigned.contains($0) }
            .compactMap { path -> (path: String, distance: TimeInterval)? in
                guard let head = CodexTranscript.readHead(path: path),
                      let metadata = CodexTranscript.metadata(head: head),
                      URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path == expectedCwd
                else { return nil }
                let distance = abs(metadata.timestamp.timeIntervalSince1970
                                   - TimeInterval(entry.created))
                return distance <= 120 ? (path, distance) : nil
            }
            .sorted {
                $0.distance == $1.distance ? $0.path < $1.path : $0.distance < $1.distance
            }
            .first?.path
    }

    private func changed(path: String, name: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return false }
        let mark = FileMark(size: size, mtime: mtime)
        if marks[name] == mark { return false }
        marks[name] = mark
        return true
    }

    private func emit(name: String, model: String) {
        if models[name] != model {
            models[name] = model
            onModelChanged?(name, model)
        }
    }
}
