import XCTest
@testable import CoveyKit

final class PMModelsTests: XCTestCase {
    func testIdleThresholdParsesSuffixes() {
        XCTAssertEqual(PMIdleThreshold.parse("30m"), 1800)
        XCTAssertEqual(PMIdleThreshold.parse("2h"), 7200)
        XCTAssertEqual(PMIdleThreshold.parse("3d"), 259_200)
        XCTAssertNil(PMIdleThreshold.parse("30"))   // без суффикса не парсится
        XCTAssertNil(PMIdleThreshold.parse("m5"))
        XCTAssertNil(PMIdleThreshold.parse("-5m"))
    }

    func testTransitionsAutoOnBind() {
        XCTAssertEqual(PMTaskTransitions.autoOnBind(.ready), .inProgress)
        XCTAssertNil(PMTaskTransitions.autoOnBind(.inProgress))  // уже в работе
        XCTAssertNil(PMTaskTransitions.autoOnBind(.done))        // терминальный не поднимается автоматом
    }

    func testTransitionsHuman() {
        XCTAssertTrue(PMTaskTransitions.human(.inProgress, .done))
        XCTAssertTrue(PMTaskTransitions.human(.inProgress, .failed))
        XCTAssertTrue(PMTaskTransitions.human(.ready, .cancelled))
        XCTAssertTrue(PMTaskTransitions.human(.done, .inProgress))      // reopen
        XCTAssertTrue(PMTaskTransitions.human(.failed, .archived))
        XCTAssertFalse(PMTaskTransitions.human(.done, .ready))          // только reopen в in_progress
        XCTAssertFalse(PMTaskTransitions.human(.ready, .inProgress))    // это авто-переход bind/spawn
        XCTAssertFalse(PMTaskTransitions.human(.archived, .inProgress)) // архив не открывается
    }

    func testLifecycleRoundTripCodable() throws {
        let t = PMTask(id: "t1", projectID: "p1", title: "T", body: "",
                       kind: "implementation", lifecycle: .inProgress,
                       assignee: "agent", idleThresholdSeconds: 1800,
                       revision: 3, createdAt: 1, updatedAt: 2, closedAt: nil)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(PMTask.self, from: data), t)
        XCTAssertEqual(t.lifecycle.rawValue, "in_progress")
    }
}
