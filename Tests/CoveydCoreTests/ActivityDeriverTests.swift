import XCTest
import CoveyKit
@testable import CoveydCore

final class ActivityDeriverTests: XCTestCase {
    private func binding(_ task: String, session: String, from: Int64) -> PMBinding {
        PMBinding(id: "b-\(session)", taskID: task, coveySession: session,
                  startedAt: from, endedAt: nil)
    }

    func testRunningSessionIsActiveRegardlessOfAge() {
        let d = ActivityDeriver()
        d.onStatus(name: "s1", status: .running, now: 1000)
        let a = d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                           idleThresholdOf: { _ in 60 }, defaultIdleS: 900, now: 10_000)
        XCTAssertEqual(a, .active)   // running перевешивает возраст lastRunningAt
    }

    func testPausedAfterIdleThreshold() {
        let d = ActivityDeriver()
        d.onStatus(name: "s1", status: .running, now: 1000)
        d.onStatus(name: "s1", status: .idle, now: 1100)   // последний запуск был в 1100
        var thresholds: [String: Int] = ["t": 900]
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                                  idleThresholdOf: { thresholds[$0] ?? 60 },
                                  defaultIdleS: 60, now: 1100 + 899), .active)
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                                  idleThresholdOf: { thresholds[$0] ?? 60 },
                                  defaultIdleS: 60, now: 1100 + 900), .paused)
        thresholds["t"] = 1800    // per-task порог больше — всё ещё active
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                                  idleThresholdOf: { thresholds[$0] ?? 60 },
                                  defaultIdleS: 60, now: 1100 + 900), .active)
    }

    func testWaitingCountsAsIdleTime() {
        let d = ActivityDeriver()
        d.onStatus(name: "s1", status: .running, now: 1000)
        d.onStatus(name: "s1", status: .waiting, now: 1050)  // агент спросил и ждёт
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                                  idleThresholdOf: { _ in 900 }, defaultIdleS: 900,
                                  now: 1050 + 901), .paused)
    }

    func testNoOpenBindingsIsIdle() {
        let d = ActivityDeriver()
        d.onStatus(name: "s1", status: .running, now: 1000)
        XCTAssertEqual(d.activity(openBindings: [], idleThresholdOf: { _ in 900 },
                                  defaultIdleS: 900, now: 1000), .idle)
    }

    func testRemovedSessionStopsContributing() {
        let d = ActivityDeriver()
        d.onStatus(name: "s1", status: .running, now: 1000)
        d.onSessionRemoved(name: "s1")
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 1000)],
                                  idleThresholdOf: { _ in 900 }, defaultIdleS: 900,
                                  now: 1000), .paused)  // неизвестная сессия ≠ active
    }

    func testSnapshotSeedsKnownSessions() {
        let d = ActivityDeriver()
        d.snapshot(names: ["s1"], statuses: ["s1": Status.waiting], now: 500)
        // статус известен, но lastRunningAt = момент снапшота — сразу не paused
        XCTAssertEqual(d.activity(openBindings: [binding("t", session: "s1", from: 400)],
                                  idleThresholdOf: { _ in 900 }, defaultIdleS: 900,
                                  now: 500), .active)
    }
}
