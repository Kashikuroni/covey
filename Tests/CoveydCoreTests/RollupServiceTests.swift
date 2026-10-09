import XCTest
import CoveyKit
@testable import CoveydCore

final class RollupServiceTests: XCTestCase {
    private let minute: Int64 = 60_000

    private func bucket(_ ms: Int64, key: String, model: String = "claude-opus-4",
                        input: Double = 10, output: Double = 5) -> TokenBucket {
        TokenBucket(m: ms, s: key, model: model, x: false,
                    input: input, output: output, cacheCreation: 0, cacheRead: 0)
    }

    func testMinuteAttributionInsideOutsideInterval() {
        // s1 привязана к задаче t1 с 10:00 до 10:02 (ms), вёдра в 09:59, 10:00, 10:02
        let start: Int64 = 600_000
        let bindings = [PMBinding(id: "b1", taskID: "t1", coveySession: "s1",
                                  startedAt: start / 1000, endedAt: (start + 2 * minute) / 1000)]
        let buckets = [
            bucket(start - minute, key: "ext-1"),   // до привязки
            bucket(start, key: "ext-1"),            // внутри
            bucket(start + 2 * minute, key: "ext-1") // после конца (endMs exclusive)
        ]
        let rows = RollupCore.compute(
            buckets: buckets, bindings: bindings,
            externalKeys: ["s1": ["ext-1"]], projectOfSession: ["s1": "p1"],
            nowMs: start + 10 * minute)
        let taskRows = rows.filter { $0.taskID == "t1" }
        let unbound = rows.filter { $0.taskID == "" }
        XCTAssertEqual(taskRows.count, 1)
        XCTAssertEqual(taskRows[0].input, 10)
        XCTAssertEqual(taskRows[0].activeMinutes, 1)
        // Две непривязанные минуты одной (сессия × модель × день) агрегируются
        // в одну строку — минуты не теряются (Review Focus №4), суммируются.
        XCTAssertEqual(unbound.count, 1)
        XCTAssertEqual(unbound[0].input, 20)
        XCTAssertEqual(unbound[0].activeMinutes, 2)
        XCTAssertEqual(unbound[0].projectID, "p1")
        XCTAssertEqual(unbound[0].agentSessionID, "sess:s1")
    }

    func testOpenIntervalClampedToNow() {
        let bindings = [PMBinding(id: "b1", taskID: "t1", coveySession: "s1",
                                  startedAt: 100, endedAt: nil)]
        let rows = RollupCore.compute(
            buckets: [bucket(200_000, key: "ext-1")], bindings: bindings,
            externalKeys: ["s1": ["ext-1"]], projectOfSession: ["s1": "p1"],
            nowMs: 300_000)
        XCTAssertEqual(rows.filter { $0.taskID == "t1" }.count, 1)
    }

    func testModelsSplitIntoSeparateRows() {
        let bindings = [PMBinding(id: "b1", taskID: "t1", coveySession: "s1",
                                  startedAt: 0, endedAt: nil)]
        let rows = RollupCore.compute(
            buckets: [bucket(0, key: "ext-1", model: "m-a"),
                      bucket(0, key: "ext-1", model: "m-b")],
            bindings: bindings, externalKeys: ["s1": ["ext-1"]],
            projectOfSession: ["s1": "p1"], nowMs: minute)
        XCTAssertEqual(rows.filter { $0.taskID == "t1" }.count, 2)
    }

    func testDayStringUTC() {
        XCTAssertEqual(RollupCore.dayStringUTC(0), "1970-01-01")
        // 2026-10-09 00:00 UTC = 1791504000s
        XCTAssertEqual(RollupCore.dayStringUTC(1_791_504_000_000), "2026-10-09")
        // 23:59 UTC ещё 9-е, в локальной зоне может быть 10-е — всегда UTC
        XCTAssertEqual(RollupCore.dayStringUTC(1_791_504_000_000 + 86_399_000), "2026-10-09")
    }

    func testServiceRecomputeIdempotentAndLateBind() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        let db = try PMDB(path: path)
        let now = Date().timeIntervalSince1970
        let nowMs = Int64(now * 1000)
        var buckets = [bucket(nowMs - minute, key: "ext-1", input: 100, output: 50)]
        let service = RollupService(
            db: db,
            loadBuckets: { buckets },
            loadBindings: { [PMBinding(id: "b1", taskID: "t1", coveySession: "s1",
                                       startedAt: Int64(now) - 120, endedAt: nil)] },
            externalKeys: { ["s1": ["ext-1"]] },
            projectOfSession: { _ in "p1" })
        try service.recompute(nowMs: nowMs)
        let count1 = try db.query("SELECT SUM(input) FROM rollup_day_task WHERE task_id='t1'", []) { $0.double(0) }.first
        XCTAssertEqual(count1, 100)
        try service.recompute(nowMs: nowMs)   // идемпотентность: тот же результат
        let count2 = try db.query("SELECT SUM(input) FROM rollup_day_task WHERE task_id='t1'", []) { $0.double(0) }.first
        XCTAssertEqual(count2, 100)           // Review Focus №3: внутри окна — пересчиталось бы корректно
        // Late bind: новая минута другой модели — recompute переписывает день
        buckets.append(bucket(nowMs - minute, key: "ext-1", model: "m-b", input: 7))
        try service.recompute(nowMs: nowMs)
        let total = try db.query("SELECT SUM(input) FROM rollup_day_task WHERE day=?",
                                 [.text(RollupCore.dayStringUTC(nowMs))] ) { $0.double(0) }.first
        XCTAssertEqual(total, 107)
    }

    func testFrozenDaysNotRewritten() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        let db = try PMDB(path: path)
        // Руками сеем строку 30-дневной давности (замороженный день)
        let oldDay = RollupCore.dayStringUTC(Int64(Date().timeIntervalSince1970 * 1000) - 30 * 86_400_000)
        try db.run("""
            INSERT INTO rollup_day_task (day, project_id, task_id, agent_session_id, model, input)
            VALUES (?,?,?,?,?,?)
            """, [.text(oldDay), .text("p1"), .text("old-task"), .text("old-b"), .text("m"), .int(42)])
        let service = RollupService(db: db, loadBuckets: { [] }, loadBindings: { [] },
                                    externalKeys: { [:] }, projectOfSession: { _ in nil })
        try service.recompute(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        let kept = try db.query("SELECT input FROM rollup_day_task WHERE day=?", [.text(oldDay)]) { $0.double(0) }
        XCTAssertEqual(kept, [42])            // Review Focus №3: старше окна — не тронуто
    }
}
