import Foundation
import CoveyKit

/// Интервалы привязок сессий к задачам (spec §7.3). Один writer — демон;
/// перепривязка сессии закрывает её предыдущий интервал (минута принадлежит
/// максимум одной задаче — инвариант для RollupService).
public final class BindingService {
    private let db: PMDB
    private let taskStore: TaskStore
    private let createSession: (String, String) throws -> Session   // (dir, prompt) → Session
    private let writePrompt: (String, [UInt8]) -> Void              // (session, bytes)

    public init(db: PMDB, taskStore: TaskStore,
                createSession: @escaping (String, String) throws -> Session = { _, _ in
                    throw PMStoreError.badRequest("spawn not wired") },
                writePrompt: @escaping (String, [UInt8]) -> Void = { _, _ in }) {
        self.db = db
        self.taskStore = taskStore
        self.createSession = createSession
        self.writePrompt = writePrompt
    }

    private static func rowToBinding(_ r: PMDB.Row) -> PMBinding {
        PMBinding(id: r.string(0), taskID: r.string(1), coveySession: r.string(2),
                  externalSessionID: r.optionalString(3), provider: r.optionalString(4),
                  startedAt: r.int(5), endedAt: r.optionalInt(6))
    }
    private static let cols = "id, task_id, covey_session, external_session_id, provider, started_at, ended_at"

    @discardableResult
    public func bind(taskID: String, session: String, now: Int64) throws -> PMBinding {
        guard try taskStore.byID(taskID) != nil else { throw PMStoreError.notFound(taskID) }
        _ = try taskStore.autoOnBind(taskID: taskID, now: now)
        // Перепривязка: у сессии не может быть двух открытых интервалов.
        try closeOpen(forSession: session, now: now)
        let id = UUID().uuidString
        try db.run("""
            INSERT INTO agent_sessions (id, task_id, covey_session, started_at)
            VALUES (?,?,?,?)
            """, [.text(id), .text(taskID), .text(session), .int(now)])
        return PMBinding(id: id, taskID: taskID, coveySession: session,
                         externalSessionID: nil, provider: nil,
                         startedAt: now, endedAt: nil)
    }

    public func unbind(bindingID: String, now: Int64) throws {
        try db.run("UPDATE agent_sessions SET ended_at=? WHERE id=? AND ended_at IS NULL",
                   [.int(now), .text(bindingID)])
    }

    public func closeOpen(forSession session: String, now: Int64) throws {
        try db.run("""
            UPDATE agent_sessions SET ended_at=?
            WHERE covey_session=? AND ended_at IS NULL
            """, [.int(now), .text(session)])
    }

    /// На старте демона: закрыть интервалы сессий, которых больше нет (spec §11).
    public func closeOpen(notIn liveSessions: Set<String>, now: Int64) throws {
        for b in try openBindings() where !liveSessions.contains(b.coveySession) {
            try unbind(bindingID: b.id, now: now)
        }
    }

    public func openBindings() throws -> [PMBinding] {
        try db.query("SELECT \(Self.cols) FROM agent_sessions WHERE ended_at IS NULL",
                     [], Self.rowToBinding)
    }

    public func openBindings(taskID: String) throws -> [PMBinding] {
        try db.query("""
            SELECT \(Self.cols) FROM agent_sessions
            WHERE ended_at IS NULL AND task_id=? ORDER BY started_at
            """, [.text(taskID)], Self.rowToBinding)
    }

    public func bindingsForTask(taskID: String) throws -> [PMBinding] {
        try db.query("SELECT \(Self.cols) FROM agent_sessions WHERE task_id=? ORDER BY started_at",
                     [.text(taskID)], Self.rowToBinding)
    }

    public func setExternalSessionID(bindingID: String, key: String) throws {
        try db.run("UPDATE agent_sessions SET external_session_id=? WHERE id=?",
                   [.text(key), .text(bindingID)])
    }

    /// coveySession → известные внешние ключи (для джойна с вёдрами TokenAggregator).
    public func externalSessionMap() throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        let rows = try db.query("SELECT covey_session, external_session_id FROM agent_sessions",
                                []) { ($0.string(0), $0.optionalString(1)) }
        for (session, key) in rows {
            if let key { out[session, default: []].insert(key) }
        }
        return out
    }

    /// Spawn из задачи (spec D2): создать сессию в корне проекта, промпт =
    /// title + "\n\n" + body, интервал с момента создания.
    public func spawn(taskID: String, now: Int64) throws -> Session {
        guard let task = try taskStore.byID(taskID) else { throw PMStoreError.notFound(taskID) }
        guard let projectRoot = try projectRootOf(task.projectID) else {
            throw PMStoreError.notFound(task.projectID)
        }
        let prompt = "\(task.title)\n\n\(task.body)\n"
        let session = try createSession(projectRoot, prompt)
        _ = try taskStore.autoOnBind(taskID: taskID, now: now)
        try closeOpen(forSession: session.name, now: now)
        let id = UUID().uuidString
        try db.run("""
            INSERT INTO agent_sessions (id, task_id, covey_session, provider, started_at)
            VALUES (?,?,?,?,?)
            """, [.text(id), .text(taskID), .text(session.name),
                  .text(session.providerId ?? "anthropic"), .int(now)])
        writePrompt(session.name, Array(prompt.utf8))
        return session
    }

    private func projectRootOf(_ projectID: String) throws -> String? {
        try db.query("SELECT root_path FROM projects WHERE id=?", [.text(projectID)]) {
            $0.string(0)
        }.first
    }
}
