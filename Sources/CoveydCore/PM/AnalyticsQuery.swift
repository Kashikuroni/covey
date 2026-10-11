import Foundation
import CoveyKit

public final class AnalyticsQuery {
    private let db: PMDB
    private let prices: [PMPrice]

    public init(db: PMDB, prices: [PMPrice]) {
        self.db = db
        self.prices = prices
    }

    private func sinceDays(_ rangeDays: Int, now: Int64) -> String {
        if rangeDays < 0 { return "0000" }   // «All»
        return RollupCore.dayStringUTC((now - Int64(rangeDays) * 86_400) * 1000)
    }

    public func projectSummary(projectID: String?, rangeDays: Int, now: Int64) throws -> PMProjectAnalytics {
        let since = sinceDays(rangeDays, now: now)
        var whereClause = "WHERE r.day >= ?"
        var params: [PMDB.Value] = [.text(since)]
        if let projectID {
            whereClause += " AND r.project_id = ?"
            params.append(.text(projectID))
        }
        // PMDB.Row держит сырой sqlite3_stmt — значения читаются только внутри
        // замыкания (до finalize); наружу уходят туплы.
        let rows = try db.query("""
            SELECT r.model, SUM(r.input), SUM(r.output), SUM(r.cache_creation),
                   SUM(r.cache_read), SUM(r.active_minutes)
            FROM rollup_day_task r
            \(whereClause)
            GROUP BY r.model ORDER BY SUM(r.input) DESC
            """, params) {
            (model: $0.string(0), input: $0.double(1), output: $0.double(2),
             cacheCreation: $0.double(3), cacheRead: $0.double(4),
             activeMinutes: $0.int(5))
        }

        var byModel: [PMModelStat] = []
        var totals = PMTokenTotals()
        var costSum = 0.0
        var allPriced = true
        for r in rows {
            let t = PMTokenTotals(input: r.input, output: r.output,
                                  cacheCreation: r.cacheCreation, cacheRead: r.cacheRead,
                                  activeMinutes: Int(r.activeMinutes))
            let cost = PMPrices.cost(for: r.model, prices: prices,
                                      input: t.input, output: t.output,
                                      cacheRead: t.cacheRead, cacheWrite: t.cacheCreation)
            if cost == nil { allPriced = false } else { costSum += cost! }
            byModel.append(PMModelStat(model: r.model, tokens: t, costUSD: cost,
                                       tasksDone: 0, tasksFailed: 0))
            totals.input += t.input; totals.output += t.output
            totals.cacheCreation += t.cacheCreation; totals.cacheRead += t.cacheRead
            totals.activeMinutes += t.activeMinutes
        }
        // Успешность моделей: (модель, lifecycle) → distinct задачи
        var doneByModel: [String: Set<String>] = [:]
        var failByModel: [String: Set<String>] = [:]
        let taskRows = try db.query("""
            SELECT r.model, t.lifecycle, t.id
            FROM rollup_day_task r
            JOIN agent_sessions b ON b.id = r.agent_session_id
            JOIN tasks t ON t.id = b.task_id
            \(whereClause) AND t.lifecycle IN ('done','failed')
            GROUP BY r.model, t.lifecycle, t.id
            """, params) { ($0.string(0), $0.string(1), $0.string(2)) }
        for (model, lifecycle, id) in taskRows {
            if lifecycle == "done" { doneByModel[model, default: []].insert(id) }
            else { failByModel[model, default: []].insert(id) }
        }
        for i in byModel.indices {
            byModel[i].tasksDone = doneByModel[byModel[i].model]?.count ?? 0
            byModel[i].tasksFailed = failByModel[byModel[i].model]?.count ?? 0
        }

        var counts: [String: Int] = [:]
        var taskParams: [PMDB.Value] = []
        var taskWhere = "WHERE lifecycle != 'archived'"
        if let projectID {
            taskWhere += " AND project_id = ?"
            taskParams.append(.text(projectID))
        }
        let countRows = try db.query(
            "SELECT lifecycle, COUNT(*) FROM tasks \(taskWhere) GROUP BY lifecycle",
            taskParams) { ($0.string(0), $0.int(1)) }
        for (lifecycle, n) in countRows {
            counts[lifecycle] = Int(n)
        }
        return PMProjectAnalytics(projectID: projectID, taskCounts: counts,
                                  totals: totals,
                                  costUSD: allPriced ? costSum : nil,
                                  allModelsPriced: allPriced, byModel: byModel,
                                  tasksDone: counts["done"] ?? 0,
                                  tasksFailed: counts["failed"] ?? 0)
    }

    public func taskTimeline(taskID: String, rangeDays: Int, now: Int64) throws -> [PMTaskTimelineEntry] {
        let since = sinceDays(rangeDays, now: now)
        let bindings = try db.query("""
            SELECT id, covey_session, started_at, ended_at FROM agent_sessions
            WHERE task_id=? ORDER BY started_at
            """, [.text(taskID)]) {
            (id: $0.string(0), session: $0.string(1),
             startedAt: $0.int(2), endedAt: $0.optionalInt(3))
        }
        return bindings.map { b in
            let rows = (try? db.query("""
                SELECT model, SUM(input), SUM(output), SUM(cache_creation),
                       SUM(cache_read), SUM(active_minutes)
                FROM rollup_day_task WHERE agent_session_id=? AND day >= ?
                GROUP BY model ORDER BY SUM(output) DESC
                """, [.text(b.id), .text(since)]) {
                (model: $0.string(0), input: $0.double(1), output: $0.double(2),
                 cacheCreation: $0.double(3), cacheRead: $0.double(4),
                 activeMinutes: $0.int(5))
            }) ?? []
            var tokens = PMTokenTotals()
            var cost = 0.0
            var priced = !rows.isEmpty
            let dominant: String? = rows.first?.model
            for r in rows {
                tokens.input += r.input; tokens.output += r.output
                tokens.cacheCreation += r.cacheCreation; tokens.cacheRead += r.cacheRead
                tokens.activeMinutes += Int(r.activeMinutes)
                let c = PMPrices.cost(for: r.model, prices: prices,
                                      input: r.input, output: r.output,
                                      cacheRead: r.cacheRead, cacheWrite: r.cacheCreation)
                if let c { cost += c } else { priced = false }
            }
            return PMTaskTimelineEntry(bindingID: b.id, coveySession: b.session,
                                       startedAt: b.startedAt, endedAt: b.endedAt,
                                       model: dominant, tokens: tokens,
                                       costUSD: priced && !rows.isEmpty ? cost : nil)
        }
    }
}
