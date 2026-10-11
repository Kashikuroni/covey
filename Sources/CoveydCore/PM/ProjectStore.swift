import Foundation
import CoveyKit

public enum PMStoreError: Error, Equatable {
    case duplicate(String)
    case notFound(String)
    case stale
    case badRequest(String)
}

public final class ProjectStore {
    private let db: PMDB

    public init(db: PMDB) { self.db = db }

    private func rowToProject(_ r: PMDB.Row) -> PMProject {
        PMProject(id: r.string(0), rootPath: r.string(1), name: r.string(2),
                  sortOrder: Int(r.int(3)), archivedAt: r.optionalInt(4),
                  revision: r.int(5), createdAt: r.int(6))
    }
    private static let cols = "id, root_path, name, sort_order, archived_at, revision, created_at"

    public func list(includeArchived: Bool) throws -> [PMProject] {
        let sql = includeArchived
            ? "SELECT \(Self.cols) FROM projects ORDER BY sort_order, root_path"
            : "SELECT \(Self.cols) FROM projects WHERE archived_at IS NULL ORDER BY sort_order, root_path"
        return try db.query(sql, []) {
            let p = rowToProject($0)
            var copy = p
            copy.missing = !FileManager.default.fileExists(atPath: p.rootPath)
            return copy
        }
    }

    @discardableResult
    public func register(rootPath: String, name: String?, now: Int64) throws -> PMProject {
        let root = pmProjectRoot(rootPath)
        if let existing = try byRoot(root) { return existing }
        let id = UUID().uuidString
        let order = try db.query("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM projects", []) { $0.int(0) }.first ?? 0
        try db.run("""
            INSERT INTO projects (id, root_path, name, sort_order, created_at)
            VALUES (?,?,?,?,?)
            """, [.text(id), .text(root), .text(name ?? pmProjectDefaultName(root)),
                  .int(order), .int(now)])
        return try byID(id)!
    }

    public func byID(_ id: String) throws -> PMProject? {
        try db.query("SELECT \(Self.cols) FROM projects WHERE id=?", [.text(id)], rowToProject).first
    }

    public func byRoot(_ root: String) throws -> PMProject? {
        try db.query("SELECT \(Self.cols) FROM projects WHERE root_path=?",
                     [.text(pmProjectRoot(root))], rowToProject).first
    }

    public func roots() -> [String] {
        (try? db.query("SELECT root_path FROM projects", []) { $0.string(0) }) ?? []
    }

    @discardableResult
    public func rename(id: String, to name: String, expectedRevision: Int64, now: Int64) throws -> PMProject {
        return try bump(id, sql: "UPDATE projects SET name=?, revision=revision+1 WHERE id=? AND revision=?",
                        params: [.text(name), .text(id), .int(expectedRevision)])
    }

    @discardableResult
    public func archive(id: String, archived: Bool, expectedRevision: Int64, now: Int64) throws -> PMProject {
        let ts: PMDB.Value = archived ? .int(now) : .null
        return try bump(id, sql: "UPDATE projects SET archived_at=?, revision=revision+1 WHERE id=? AND revision=?",
                        params: [ts, .text(id), .int(expectedRevision)])
    }

    public func reorder(ids: [String]) throws {
        for (i, id) in ids.enumerated() {
            try db.run("UPDATE projects SET sort_order=? WHERE id=?", [.int(Int64(i)), .text(id)])
        }
    }

    /// Сессия → проект: longest-prefix по зарегистрированным корням (spec §6).
    public func projectID(forSessionRoot root: String) -> String? {
        guard let matched = PMAttribution.projectRoot(for: root, registered: roots()) else { return nil }
        return (try? byRoot(matched))??.id
    }

    /// Одноразовая миграция projects/projectNames/projectOrder из state.json (spec §10).
    /// Возвращает число импортированных проектов; повторный вызов — no-op.
    @discardableResult
    public func seed(from state: PersistedState, now: Int64) throws -> Int {
        let roots = state.projects ?? []
        guard !roots.isEmpty else { return 0 }
        let order = state.projectOrder ?? []
        var imported = 0
        for root in roots {
            if try byRoot(root) != nil { continue }
            let name = state.projectNames?[root] ?? pmProjectDefaultName(root)
            let sortOrder = order.firstIndex(of: root).map(Int64.init) ?? Int64(roots.count)
            let id = UUID().uuidString
            try db.run("""
                INSERT INTO projects (id, root_path, name, sort_order, created_at)
                VALUES (?,?,?,?,?)
                """, [.text(id), .text(pmProjectRoot(root)), .text(name), .int(sortOrder), .int(now)])
            imported += 1
        }
        return imported
    }

    // MARK: - private

    @discardableResult
    private func bump(_ id: String, sql: String, params: [PMDB.Value]) throws -> PMProject {
        try db.run(sql, params)
        guard try db.query("SELECT changes()", []) { $0.int(0) }.first == 1 else {
            // 0 строк: либо нет id, либо ревизия не совпала.
            if try byID(id) == nil { throw PMStoreError.notFound(id) }
            throw PMStoreError.stale
        }
        return try byID(id)!
    }
}
