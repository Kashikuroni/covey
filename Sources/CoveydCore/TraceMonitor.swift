import Foundation
import CoveyKit

/// Polls each session's CLI log, incrementally normalizes appended bytes into
/// TraceEvents, persists them, and notifies subscribers. Same cadence pattern
/// as ModelMonitor; reuses its file-discovery helpers.
public final class TraceMonitor {
    public var onTraceAppended: ((String, [TraceEvent]) -> Void)?

    private let store: TraceStore
    private let interval: TimeInterval
    private let projectsRoot: String
    private let codexSessionsRoot: String
    private let snapshot: () -> [ModelMonitor.Entry]
    private let queue = DispatchQueue(label: "covey.trace.monitor")
    private var timer: DispatchSourceTimer?

    private struct State {
        var key: String
        var path: String
        var offset: UInt64
        var seq: Int
        var claude: ClaudeTraceAdapter?
        var codex: CodexTraceAdapter?
    }
    private var states: [String: State] = [:]         // session name -> State
    private var codexAssigned: Set<String> = []

    public init(store: TraceStore, interval: TimeInterval = 5,
                projectsRoot: String = NSHomeDirectory() + "/.claude/projects",
                codexSessionsRoot: String = NSHomeDirectory() + "/.codex/sessions",
                snapshot: @escaping () -> [ModelMonitor.Entry]) {
        self.store = store; self.interval = interval
        self.projectsRoot = projectsRoot; self.codexSessionsRoot = codexSessionsRoot
        self.snapshot = snapshot
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tickBody() }
        timer = t; t.resume()
    }
    public func stop() { timer?.cancel(); timer = nil }
    public func tick() { queue.sync { tickBody() } }
    public func poke(entry: ModelMonitor.Entry) { queue.async { [weak self] in self?.read(entry) } }
    public func sessionKey(name: String) -> String? { queue.sync { states[name]?.key } }

    private func tickBody() {
        var seen = Set<String>()
        for entry in snapshot() { seen.insert(entry.name); read(entry) }
        for (name, state) in states where !seen.contains(name) {
            codexAssigned.remove(state.path); states[name] = nil
        }
    }

    private func read(_ entry: ModelMonitor.Entry) {
        ensureState(entry)
        guard var state = states[entry.name] else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: state.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < state.offset {   // truncation / rotation
            state.offset = 0; state.seq = store.lastSeq(sessionKey: state.key) + 1
            if state.claude != nil { state.claude = ClaudeTraceAdapter() }
            if state.codex != nil { state.codex = CodexTraceAdapter() }
        }
        guard size > state.offset,
              let handle = FileHandle(forReadingAtPath: state.path) else {
            states[entry.name] = state; return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        state.offset += UInt64(data.count)
        let lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        var seq = state.seq
        let events: [TraceEvent]
        if state.claude != nil { events = state.claude!.consume(lines: lines, seq: &seq) }
        else if state.codex != nil { events = state.codex!.consume(lines: lines, seq: &seq) }
        else { events = [] }
        state.seq = seq
        states[entry.name] = state
        if !events.isEmpty {
            store.append(sessionKey: state.key, events: events)
            onTraceAppended?(entry.name, events)
        }
    }

    /// Resolve the source file + adapter for a session once; memoized in `states`.
    private func ensureState(_ entry: ModelMonitor.Entry) {
        if states[entry.name] != nil { return }
        if let uuid = ClaudeTranscript.sessionUUID(resumeCmd: entry.resumeCmd) {
            let path = ClaudeTranscript.path(projectsRoot: projectsRoot, cwd: entry.cwd, uuid: uuid)
            states[entry.name] = State(key: uuid, path: path,
                offset: 0, seq: store.lastSeq(sessionKey: uuid) + 1,
                claude: ClaudeTraceAdapter(), codex: nil)
        } else if CodexTranscript.isCodexAgent(entry.agent),
                  let path = discoverCodexPath(entry) {
            let key = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            codexAssigned.insert(path)
            states[entry.name] = State(key: key, path: path,
                offset: 0, seq: store.lastSeq(sessionKey: key) + 1,
                claude: nil, codex: CodexTraceAdapter())
        }
    }

    private func discoverCodexPath(_ entry: ModelMonitor.Entry) -> String? {
        let expected = URL(fileURLWithPath: entry.cwd).standardizedFileURL.path
        return CodexTranscript.rolloutPaths(sessionsRoot: codexSessionsRoot, created: entry.created)
            .filter { !codexAssigned.contains($0) }
            .compactMap { path -> (String, TimeInterval)? in
                guard let head = CodexTranscript.readHead(path: path),
                      let meta = CodexTranscript.metadata(head: head),
                      URL(fileURLWithPath: meta.cwd).standardizedFileURL.path == expected
                else { return nil }
                let d = abs(meta.timestamp.timeIntervalSince1970 - TimeInterval(entry.created))
                return d <= 120 ? (path, d) : nil
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .first?.0
    }
}
