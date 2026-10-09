import XCTest
import CoveyKit
@testable import CoveydCore

final class BindingServiceTests: XCTestCase {
    private var db: PMDB!
    private var tasks: TaskStore!
    private var projects: ProjectStore!
    private var bindings: BindingService!

    override func setUpWithError() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        db = try PMDB(path: path)
        projects = ProjectStore(db: db)
        tasks = TaskStore(db: db)
        bindings = BindingService(db: db, taskStore: tasks)
    }

    private func makeTask() throws -> (PMProject, PMTask) {
        let p = try projects.register(rootPath: "/dev/\(UUID().uuidString.prefix(6))",
                                      name: nil, now: 1)
        let t = try tasks.create(projectID: p.id, title: "T", body: "B",
                                 assignee: nil, idleThresholdS: nil, now: 1)
        return (p, t)
    }

    func testBindOpensIntervalAndBumpsLifecycle() throws {
        let (_, t) = try makeTask()
        let b = try bindings.bind(taskID: t.id, session: "s1", now: 100)
        XCTAssertNil(b.endedAt)
        XCTAssertEqual(try tasks.byID(t.id)?.lifecycle, .inProgress)
    }

    func testRebindClosesPreviousInterval() throws {
        let (_, t1) = try makeTask()
        let (_, t2) = try makeTask()
        _ = try bindings.bind(taskID: t1.id, session: "s1", now: 100)
        let second = try bindings.bind(taskID: t2.id, session: "s1", now: 200)
        let first = try bindings.bindingsForTask(taskID: t1.id).first!
        XCTAssertEqual(first.endedAt, 200)          // интервал закрыт в момент перепривязки
        XCTAssertNil(second.endedAt)
        XCTAssertEqual(second.taskID, t2.id)
    }

    func testUnbindAndCloseOnSessionExit() throws {
        let (_, t) = try makeTask()
        let b = try bindings.bind(taskID: t.id, session: "s1", now: 100)
        try bindings.unbind(bindingID: b.id, now: 150)
        XCTAssertEqual(try bindings.bindingsForTask(taskID: t.id).first?.endedAt, 150)

        _ = try bindings.bind(taskID: t.id, session: "s2", now: 160)
        try bindings.closeOpen(forSession: "s2", now: 170)
        let refreshed = try bindings.bindingsForTask(taskID: t.id).last!
        XCTAssertEqual(refreshed.endedAt, 170)
        XCTAssertFalse(refreshed.covers(170 * 1000))   // endMs exclusive
    }

    func testExternalSessionMap() throws {
        let (_, t) = try makeTask()
        let b = try bindings.bind(taskID: t.id, session: "s1", now: 100)
        try bindings.setExternalSessionID(bindingID: b.id, key: "uuid-42")
        XCTAssertEqual(try bindings.externalSessionMap()["s1"], ["uuid-42"])
    }

    func testSpawnCreatesSessionAndBindingAndWritesPrompt() throws {
        let (p, t) = try makeTask()
        var promptWritten: [UInt8]? = nil
        let created = Session(name: "spawned-1", dir: p.rootPath, cwd: p.rootPath,
                              agent: "claude", created: 300)
        let service = BindingService(db: db, taskStore: tasks,
                                     createSession: { _, _ in created },
                                     writePrompt: { name, bytes in
                                         XCTAssertEqual(name, "spawned-1")
                                         promptWritten = bytes
                                     })
        let session = try service.spawn(taskID: t.id, now: 300)
        XCTAssertEqual(session.name, "spawned-1")
        let open = try service.openBindings(taskID: t.id)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.coveySession, "spawned-1")
        XCTAssertEqual(open.first?.startedAt, 300)
        XCTAssertEqual(String(decoding: promptWritten ?? [], as: UTF8.self), "T\n\nB\n")
        XCTAssertEqual(try tasks.byID(t.id)?.lifecycle, .inProgress)
    }
}
