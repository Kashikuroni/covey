import Foundation
import SQLite3

/// Минимальная обёртка системного SQLite3 для pm.db. Один файл, WAL, версия
/// схемы в PRAGMA user_version. Признаки порчи (открытие/prepare/интегрити) →
/// файл переименовывается в .corrupt-<ts> и БД создаётся заново (spec §11).
/// Потокобезопасность обеспечивается владельцем (PMService — serial queue);
/// сама обёртка не синхронизирована.
public final class PMDB {
    public enum PMDBError: Error, Equatable {
        case open(String), sql(String)
    }

    public enum Value {
        case text(String), int(Int64), double(Double), null
        var bind: (OpaquePointer?, Int32) -> Void { { stmt, idx in
            switch self {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let i): sqlite3_bind_int64(stmt, idx, i)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        } }
    }

    public struct Row {
        let stmt: OpaquePointer?
        public func string(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func optionalString(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : string(i)
        }
        public func optionalInt(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : int(i)
        }
    }

    public static let latestSchemaVersion = 1
    private var handle: OpaquePointer?
    public let path: String
    /// Non-nil, если файл был признан порченным и заменён свежей БД (finding 7:
    /// потеря данных должна быть видимой — main.swift логирует и шлёт событие).
    public private(set) var recoveryNote: String?

    public init(path: String) throws {
        self.path = path
        try openAndMigrate(recovered: false)
    }

    private func openAndMigrate(recovered: Bool) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let opened = db else {
            sqlite3_close(db)
            if recovered { throw PMDBError.open(path) }
            return try recoverCorruptThenRetry()
        }
        handle = opened
        do {
            try execute("PRAGMA journal_mode=WAL")
            let ok = try query("PRAGMA quick_check", []) { $0.string(0) }.first == "ok"
            guard ok else { throw PMDBError.sql("quick_check failed") }
            try migrateIfNeeded()
        } catch {
            close()
            if recovered { throw PMDBError.open(path) }
            return try recoverCorruptThenRetry()
        }
    }

    private func recoverCorruptThenRetry() throws {
        let ts = Int64(Date().timeIntervalSince1970)
        let corrupt = "\(path).corrupt-\(ts)"
        try? FileManager.default.removeItem(atPath: corrupt)
        try? FileManager.default.moveItem(atPath: path, toPath: corrupt)
        // WAL-сайдкары уносим вместе с файлом: побочный -wal от старой БД
        // может быть воспроизведён в свежую (finding 6).
        for sidecar in ["-wal", "-shm"] {
            try? FileManager.default.moveItem(atPath: path + sidecar,
                                              toPath: corrupt + sidecar)
        }
        recoveryNote = "pm.db was corrupt; moved to \(corrupt) and started fresh"
        try openAndMigrate(recovered: true)
    }

    private func migrateIfNeeded() throws {
        let current = schemaVersion
        guard current < PMDB.latestSchemaVersion else { return }
        // Бэкап — только при обновлении старой схемы (user_version > 0):
        // свежий файл (version 0) миграцией не является, копия пустой БД не нужна.
        if current > 0 {
            // Checkpoint перед копией: без него бэкап теряет коммиты, живущие
            // в -wal (finding 6).
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
            let backup = "\(path).backup-\(Int64(Date().timeIntervalSince1970))"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        try execute("BEGIN IMMEDIATE")
        try execute(Self.schemaSQL(from: current))
        try execute("PRAGMA user_version=\(PMDB.latestSchemaVersion)")
        try execute("COMMIT")
    }

    /// Для теста: последний бэкап рядом с базой.
    public static func latestBackup(nextTo path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".backup-"
        return try? FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix(prefix) }.max()
    }

    public var schemaVersion: Int {
        (try? query("PRAGMA user_version", []) { Int($0.int(0)) }.first) ?? 0
    }

    /// DDL схемы v1 — точно по спек §6 (+ revision у projects).
    public static func schemaSQL(from version: Int) -> String {
        guard version < 1 else { return "" }
        return """
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          root_path TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          archived_at INTEGER,
          revision INTEGER NOT NULL DEFAULT 1,
          repository_id TEXT, target_ref TEXT, accepted_target_oid TEXT,
          policy_version INTEGER,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL REFERENCES projects(id),
          title TEXT NOT NULL,
          body TEXT NOT NULL DEFAULT '',
          kind TEXT NOT NULL DEFAULT 'implementation',
          lifecycle TEXT NOT NULL DEFAULT 'ready',
          assignee TEXT NOT NULL DEFAULT 'agent',
          idle_threshold_s INTEGER,
          execution_mode TEXT, branch_ref TEXT, base_oid TEXT, head_oid TEXT,
          revision INTEGER NOT NULL DEFAULT 1,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          closed_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, lifecycle);
        CREATE TABLE IF NOT EXISTS agent_sessions (
          id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL REFERENCES tasks(id),
          covey_session TEXT NOT NULL,
          external_session_id TEXT,
          provider TEXT,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          revision INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_bindings_session ON agent_sessions(covey_session, ended_at);
        CREATE TABLE IF NOT EXISTS rollup_day_task (
          day TEXT NOT NULL,
          project_id TEXT NOT NULL,
          task_id TEXT NOT NULL DEFAULT '',
          agent_session_id TEXT NOT NULL,
          model TEXT NOT NULL,
          input REAL NOT NULL DEFAULT 0,
          output REAL NOT NULL DEFAULT 0,
          cache_creation REAL NOT NULL DEFAULT 0,
          cache_read REAL NOT NULL DEFAULT 0,
          active_minutes INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, agent_session_id, model, task_id)
        );
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY,
          seq INTEGER UNIQUE,
          type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          entity_revision INTEGER,
          occurred_at INTEGER NOT NULL,
          payload TEXT
        );
        """
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw PMDBError.sql("\(msg) — \(sql.prefix(120))")
        }
    }

    public func run(_ sql: String, _ params: [Value]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PMDBError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() { p.bind(stmt, Int32(i + 1)) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PMDBError.sql(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func query<T>(_ sql: String, _ params: [Value], _ map: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PMDBError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() { p.bind(stmt, Int32(i + 1)) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    public func close() {
        sqlite3_close(handle)
        handle = nil
    }

    deinit { close() }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
