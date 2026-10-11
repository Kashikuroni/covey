import XCTest
import CoveyKit
@testable import CoveydCore

final class AnalyticsQueryTests: XCTestCase {
    private var db: PMDB!
    private var q: AnalyticsQuery!
    private let now = Int64(Date().timeIntervalSince1970)

    override func setUpWithError() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        db = try PMDB(path: path)
        q = AnalyticsQuery(db: db, prices: [
            PMPrice(match: "claude-opus", input: 15, output: 75, cacheRead: 0, cacheWrite: 0),
            PMPrice(match: "glm-", input: 1, output: 1, cacheRead: 0, cacheWrite: 0)
        ])
        // Проект p1, задачи t-done (done), t-fail (failed), t-open (in_progress)
        try db.run("INSERT INTO projects (id, root_path, name, sort_order, created_at) VALUES ('p1','/x','x',0,0)", [])
        for (id, lc) in [("t-done", "done"), ("t-fail", "failed"), ("t-open", "in_progress")] {
            try db.run("""
                INSERT INTO tasks (id, project_id, title, lifecycle, revision, created_at, updated_at, closed_at)
                VALUES (?,?,?,?,1,?,?,?)
                """, [.text(id), .text("p1"), .text(id), .text(lc),
                      .int(now - 100), .int(now - 100),
                      lc == "in_progress" ? PMDB.Value.null : .int(now)])
        }
        // Привязки: b1 → t-done (claude-opus, $0.30: 20k in × $15/M), b2 → t-fail (glm-5.3),
        // b3 → t-open (mystery — без цены)
        for (b, t, s) in [("b1", "t-done", "s1"), ("b2", "t-fail", "s2"), ("b3", "t-open", "s3")] {
            try db.run("""
                INSERT INTO agent_sessions (id, task_id, covey_session, started_at)
                VALUES (?,?,?,?)
                """, [.text(b), .text(t), .text(s), .int(now - 50)])
        }
        let day = RollupCore.dayStringUTC(now * 1000)
        let insert = """
            INSERT INTO rollup_day_task
              (day, project_id, task_id, agent_session_id, model, input, output, active_minutes)
            VALUES (?,?,?,?,?,?,?,?)
            """
        try db.run(insert, [.text(day), .text("p1"), .text("t-done"), .text("b1"), .text("claude-opus-4.5"),
                            .double(20_000), .double(0), .int(10)])
        try db.run(insert, [.text(day), .text("p1"), .text("t-fail"), .text("b2"), .text("glm-5.3"),
                            .double(1_000_000), .double(0), .int(5)])
        try db.run(insert, [.text(day), .text("p1"), .text("t-open"), .text("b3"), .text("mystery"),
                            .double(999), .double(0), .int(2)])
    }

    func testProjectSummary() throws {
        let s = try q.projectSummary(projectID: "p1", rangeDays: 7, now: now)
        XCTAssertEqual(s.tasksDone, 1)
        XCTAssertEqual(s.tasksFailed, 1)
        XCTAssertEqual(s.totals.activeMinutes, 17)
        XCTAssertEqual(s.totals.input, 1_020_999, accuracy: 0.001)
        // claude-opus $0.30 + glm $1.00, mystery без цены → costUSD nil, флаг снят
        XCTAssertNil(s.costUSD)                                  // Review Focus №5
        XCTAssertFalse(s.allModelsPriced)
        XCTAssertEqual(s.byModel.count, 3)
        let opus = s.byModel.first { $0.model == "claude-opus-4.5" }!
        XCTAssertEqual(opus.costUSD!, 0.3, accuracy: 0.0001)
        XCTAssertEqual(opus.tasksDone, 1)   // модель участвовала в done-задаче
        XCTAssertEqual(opus.tasksFailed, 0)
        let glm = s.byModel.first { $0.model == "glm-5.3" }!
        XCTAssertEqual(glm.tasksFailed, 1)
    }

    func testTimeline() throws {
        let tl = try q.taskTimeline(taskID: "t-done", rangeDays: 7, now: now)
        XCTAssertEqual(tl.count, 1)
        XCTAssertEqual(tl[0].coveySession, "s1")
        XCTAssertEqual(tl[0].model, "claude-opus-4.5")
        XCTAssertEqual(tl[0].costUSD!, 0.3, accuracy: 0.0001)
        XCTAssertEqual(tl[0].tokens.activeMinutes, 10)
    }
}
