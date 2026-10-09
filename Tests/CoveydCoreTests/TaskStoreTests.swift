import XCTest
import CoveyKit
@testable import CoveydCore

final class TaskStoreTests: XCTestCase {
    private var store: TaskStore!
    private var projects: ProjectStore!

    override func setUpWithError() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        let db = try PMDB(path: path)
        projects = ProjectStore(db: db)
        store = TaskStore(db: db)
    }

    private func makeProject() throws -> PMProject {
        try projects.register(rootPath: "/dev/p-\(UUID().uuidString.prefix(6))", name: nil, now: 1)
    }

    func testCreateDefaults() throws {
        let p = try makeProject()
        let t = try store.create(projectID: p.id, title: "Сделать X", body: "детали",
                                 assignee: nil, idleThresholdS: nil, now: 10)
        XCTAssertEqual(t.lifecycle, .ready)
        XCTAssertEqual(t.assignee, "agent")
        XCTAssertEqual(t.revision, 1)
        XCTAssertNil(t.closedAt)
    }

    func testUpdateRejectsStaleRevision() throws {
        let p = try makeProject()
        let t = try store.create(projectID: p.id, title: "T", body: "", assignee: nil,
                                 idleThresholdS: nil, now: 1)
        _ = try store.update(id: t.id, title: "T2", body: nil, idleThresholdS: nil,
                             expectedRevision: t.revision, now: 2)
        XCTAssertThrowsError(try store.update(id: t.id, title: "T3", body: nil,
                                              idleThresholdS: nil,
                                              expectedRevision: t.revision, now: 3)) {
            XCTAssertEqual(($0 as? PMStoreError), .stale)   // Review Focus №2
        }
        XCTAssertEqual(try store.byID(t.id)?.revision, 2)
    }

    func testAutoOnBindOnlyFromReady() throws {
        let p = try makeProject()
        let t = try store.create(projectID: p.id, title: "T", body: "", assignee: nil,
                                 idleThresholdS: nil, now: 1)
        let bumped = try store.autoOnBind(taskID: t.id, now: 2)
        XCTAssertEqual(bumped?.lifecycle, .inProgress)
        XCTAssertNil(try store.autoOnBind(taskID: t.id, now: 3))   // повтор — no-op
    }

    func testSetStatusHumanTransitions() throws {
        let p = try makeProject()
        let t = try store.create(projectID: p.id, title: "T", body: "", assignee: nil,
                                 idleThresholdS: nil, now: 1)
        _ = try store.autoOnBind(taskID: t.id, now: 2)
        let done = try store.setStatus(id: t.id, to: .failed, expectedRevision: 2, now: 3)
        XCTAssertEqual(done.lifecycle, .failed)
        XCTAssertEqual(done.closedAt, 3)
        XCTAssertThrowsError(try store.setStatus(id: t.id, to: .done, expectedRevision: 3, now: 4)) {
            XCTAssertEqual(($0 as? PMStoreError), .badRequest("invalid transition")) // failed → done запрещён
        }
        let reopened = try store.setStatus(id: t.id, to: .inProgress, expectedRevision: 3, now: 5)
        XCTAssertEqual(reopened.lifecycle, .inProgress)
        XCTAssertNil(reopened.closedAt)
    }

    func testListFiltersByProjectAndArchived() throws {
        let p1 = try makeProject(), p2 = try makeProject()
        _ = try store.create(projectID: p1.id, title: "A", body: "", assignee: nil,
                             idleThresholdS: nil, now: 1)
        _ = try store.create(projectID: p2.id, title: "B", body: "", assignee: nil,
                             idleThresholdS: nil, now: 1)
        XCTAssertEqual(try store.list(projectID: p1.id).count, 1)
        XCTAssertEqual(try store.list(projectID: nil).count, 2)
    }
}
