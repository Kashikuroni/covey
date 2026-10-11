import Foundation
import CoveyKit

/// Одна дневная строка rollup (spec §8.1). taskID == "" — минуты сессии вне задач.
public struct RollupRow: Codable, Equatable, Sendable {
    public var day: String
    public var projectID: String
    public var taskID: String
    public var agentSessionID: String
    public var model: String
    public var input: Double
    public var output: Double
    public var cacheCreation: Double
    public var cacheRead: Double
    public var activeMinutes: Int
}

/// Чистая атрибуция: минутное ведро → (день, проект, задача, привязка).
/// Инвариант: у одной covey-сессии интервалы не пересекаются (BindingService),
/// поэтому минута относится максимум к одной задаче.
public enum RollupCore {
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func dayStringUTC(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let c = utcCal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func compute(buckets: [TokenBucket], bindings: [PMBinding],
                               externalKeys: [String: Set<String>],
                               projectOfSession: [String: String],
                               nowMs: Int64) -> [RollupRow] {
        // coveySession → [(startMs, endMsClamped, taskID, bindingID)]
        var intervals: [String: [(Int64, Int64, String, String)]] = [:]
        for b in bindings {
            let end = (b.endedAt.map { $0 * 1000 } ?? nowMs)
            intervals[b.coveySession, default: []].append((b.startedAt * 1000, end, b.taskID, b.id))
        }
        // bucketKey → [coveySession]
        var ownersByKey: [String: [String]] = [:]
        for (session, keys) in externalKeys {
            for k in keys { ownersByKey[k, default: []].append(session) }
        }

        struct RowKey: Hashable { var day: String; var projectID: String; var taskID: String; var agentSessionID: String; var model: String }
        var acc: [RowKey: RollupRow] = [:]

        for b in buckets {
            guard let owners = ownersByKey[b.s] else { continue }
            for session in owners {
                guard let projectID = projectOfSession[session] else { continue }
                let matched = intervals[session]?.first { b.m >= $0.0 && b.m < $0.1 }
                let taskID = matched?.2 ?? ""
                let agentSessionID = matched?.3 ?? "sess:\(session)"
                let key = RowKey(day: dayStringUTC(b.m), projectID: projectID,
                                 taskID: taskID, agentSessionID: agentSessionID, model: b.model)
                var row = acc[key] ?? RollupRow(day: key.day, projectID: key.projectID,
                                                taskID: key.taskID, agentSessionID: key.agentSessionID,
                                                model: key.model, input: 0, output: 0,
                                                cacheCreation: 0, cacheRead: 0, activeMinutes: 0)
                row.input += b.input; row.output += b.output
                row.cacheCreation += b.cacheCreation; row.cacheRead += b.cacheRead
                row.activeMinutes += 1
                acc[key] = row
            }
        }
        return acc.values.sorted {
            ($0.day, $0.agentSessionID, $0.model, $0.taskID) <
            ($1.day, $1.agentSessionID, $1.model, $1.taskID)
        }
    }
}

/// Персистентная часть: пересчёт последних 7 дней (окно повторяемости сырых
/// вёдер — spec §8.1), DELETE+INSERT, идемпотентно.
public final class RollupService {
    public let recomputeWindowDays = 7
    private let db: PMDB
    private let loadBuckets: () -> [TokenBucket]
    private let loadBindings: () -> [PMBinding]
    private let externalKeys: () -> [String: Set<String>]
    private let projectOfSession: (String) -> String?

    public init(db: PMDB,
                loadBuckets: @escaping () -> [TokenBucket],
                loadBindings: @escaping () -> [PMBinding],
                externalKeys: @escaping () -> [String: Set<String>],
                projectOfSession: @escaping (String) -> String?) {
        self.db = db
        self.loadBuckets = loadBuckets
        self.loadBindings = loadBindings
        self.externalKeys = externalKeys
        self.projectOfSession = projectOfSession
    }

    public func recompute(nowMs: Int64) throws {
        let days = (0..<recomputeWindowDays).map { offset -> String in
            RollupCore.dayStringUTC(nowMs - Int64(offset) * 86_400_000)
        }
        let bindings = loadBindings()
        // Кэш projectOfSession по сессиям из привязок
        var proj: [String: String] = [:]
        for b in bindings where proj[b.coveySession] == nil {
            if let p = projectOfSession(b.coveySession) { proj[b.coveySession] = p }
        }
        let rows = RollupCore.compute(buckets: loadBuckets(), bindings: bindings,
                                      externalKeys: externalKeys(),
                                      projectOfSession: proj, nowMs: nowMs)
            .filter { days.contains($0.day) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            for day in days {
                try db.run("DELETE FROM rollup_day_task WHERE day=?", [.text(day)])
            }
            for r in rows {
                try db.run("""
                    INSERT INTO rollup_day_task
                      (day, project_id, task_id, agent_session_id, model,
                       input, output, cache_creation, cache_read, active_minutes)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [.text(r.day), .text(r.projectID), .text(r.taskID),
                          .text(r.agentSessionID), .text(r.model),
                          .double(r.input), .double(r.output),
                          .double(r.cacheCreation), .double(r.cacheRead),
                          .int(Int64(r.activeMinutes))])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }
}
