import Foundation
import CoveyKit

public final class TaskStore {
    private let db: PMDB
    public init(db: PMDB) { self.db = db }

    private static let cols = """
        id, project_id, title, body, kind, lifecycle, assignee, idle_threshold_s,
        revision, created_at, updated_at, closed_at
        """

    private func rowToTask(_ r: PMDB.Row) -> PMTask {
        PMTask(id: r.string(0), projectID: r.string(1), title: r.string(2), body: r.string(3),
               kind: r.string(4),
               lifecycle: PMTaskLifecycle(rawValue: r.string(5)) ?? .ready,
               assignee: r.string(6), idleThresholdSeconds: r.optionalInt(7).map(Int.init),
               revision: r.int(8), createdAt: r.int(9), updatedAt: r.int(10),
               closedAt: r.optionalInt(11))
    }

    @discardableResult
    public func create(projectID: String, title: String, body: String,
                       assignee: String?, idleThresholdS: Int?, now: Int64) throws -> PMTask {
        let id = UUID().uuidString
        try db.run("""
            INSERT INTO tasks (id, project_id, title, body, lifecycle, assignee,
                               idle_threshold_s, revision, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(id), .text(projectID), .text(title), .text(body),
                  .text(PMTaskLifecycle.ready.rawValue), .text(assignee ?? "agent"),
                  idleThresholdS.map { .int(Int64($0)) } ?? .null,
                  .int(1), .int(now), .int(now)])
        return try byID(id)!
    }

    public func byID(_ id: String) throws -> PMTask? {
        try db.query("SELECT \(Self.cols) FROM tasks WHERE id=?", [.text(id)], rowToTask).first
    }

    public func list(projectID: String?, includeArchived: Bool = false) throws -> [PMTask] {
        var sql = "SELECT \(Self.cols) FROM tasks"
        var params: [PMDB.Value] = []
        if let projectID {
            sql += " WHERE project_id=?"
            params.append(.text(projectID))
            if !includeArchived { sql += " AND lifecycle != 'archived'" }
        } else if !includeArchived {
            sql += " WHERE lifecycle != 'archived'"
        }
        sql += " ORDER BY updated_at DESC"
        return try db.query(sql, params, rowToTask)
    }

    @discardableResult
    public func update(id: String, title: String?, body: String?, idleThresholdS: Int?,
                       expectedRevision: Int64, now: Int64) throws -> PMTask {
        try checkedUpdate(id: id, expectedRevision: expectedRevision, sql: """
            UPDATE tasks SET
              title = COALESCE(?, title),
              body = COALESCE(?, body),
              idle_threshold_s = COALESCE(?, idle_threshold_s),
              revision = revision + 1, updated_at = ?
            WHERE id=? AND revision=?
            """, params: [title.map { .text($0) } ?? .null, body.map { .text($0) } ?? .null,
                          idleThresholdS.map { .int(Int64($0)) } ?? .null,
                          .int(now), .text(id), .int(expectedRevision)])
    }

    /// Терминальные/reopen/archive — только через человеческие переходы (spec §7.1).
    @discardableResult
    public func setStatus(id: String, to: PMTaskLifecycle,
                          expectedRevision: Int64, now: Int64) throws -> PMTask {
        guard let current = try byID(id) else { throw PMStoreError.notFound(id) }
        guard PMTaskTransitions.human(current.lifecycle, to) else {
            throw PMStoreError.badRequest("invalid transition")
        }
        let closed: PMDB.Value = (to == .done || to == .failed || to == .cancelled) ? .int(now) : .null
        return try checkedUpdate(id: id, expectedRevision: expectedRevision, sql: """
            UPDATE tasks SET lifecycle=?, closed_at=?, revision=revision+1, updated_at=?
            WHERE id=? AND revision=?
            """, params: [.text(to.rawValue), closed, .int(now), .text(id), .int(expectedRevision)])
    }

    /// Автопереход при bind/spawn: ready → in_progress. nil — уже in_progress;
    /// терминальные/архивные не поднимаются (ошибка).
    @discardableResult
    public func autoOnBind(taskID: String, now: Int64) throws -> PMTask? {
        guard let t = try byID(taskID) else { throw PMStoreError.notFound(taskID) }
        if t.lifecycle == .inProgress { return nil }
        guard let next = PMTaskTransitions.autoOnBind(t.lifecycle) else {
            throw PMStoreError.badRequest("task is closed")
        }
        return try checkedUpdate(id: taskID, expectedRevision: t.revision, sql: """
            UPDATE tasks SET lifecycle=?, revision=revision+1, updated_at=? WHERE id=? AND revision=?
            """, params: [.text(next.rawValue), .int(now), .text(taskID), .int(t.revision)])
    }

    // MARK: - private

    /// UPDATE с guard'ом ревизии: `SELECT changes()` — единственный способ
    /// отличить «мой UPDATE применился» от «ревизию поднял другой писатель»
    /// (сравнение byID с expected этого не различает).
    private func checkedUpdate(id: String, expectedRevision: Int64,
                               sql: String, params: [PMDB.Value]) throws -> PMTask {
        try db.run(sql, params)
        let changed = try db.query("SELECT changes()", []) { $0.int(0) }.first ?? 0
        guard changed == 1 else {
            if try byID(id) == nil { throw PMStoreError.notFound(id) }
            throw PMStoreError.stale
        }
        return try byID(id)!
    }
}
