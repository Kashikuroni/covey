import XCTest
import CoveyKit
@testable import CoveydCore

final class PMServiceTests: XCTestCase {
    private var service: PMService!
    private var events: [PMEventEnvelope] = []
    private var db: PMDB!

    override func setUpWithError() throws {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        db = try PMDB(path: path)
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let bindings = BindingService(db: db, taskStore: tasks)
        let rollups = RollupService(db: db, loadBuckets: { [] }, loadBindings: { [] },
                                    externalKeys: { [:] }, projectOfSession: { _ in nil })
        let analytics = AnalyticsQuery(db: db, prices: [])
        service = PMService(db: db, projects: projects, tasks: tasks, bindings: bindings,
                            rollups: rollups, analytics: analytics,
                            now: { 1000 })
        service.onEvent = { [weak self] in self?.events.append($0) }
    }

    private func makeProject() throws -> String {
        let r = try service.handle(.pmProjectsRegister(rootPath: "/dev/\(UUID().uuidString.prefix(6))"))
        guard case .pmProjects(let list) = r, let p = list.first else { throw XCTSkip("no project") }
        return p.id
    }

    func testCreateBindListRoundTrip() throws {
        let pid = try makeProject()
        let created = try service.handle(.pmTasksCreate(projectID: pid, title: "T", body: "B",
                                                        assignee: nil, idleThresholdS: 1800,
                                                        requestID: "r1"))
        guard case .pmTask(let task) = created else { return XCTFail("expected task") }
        XCTAssertEqual(task.lifecycle, .ready)

        let bound = try service.handle(.pmTasksBind(taskID: task.id, session: "s1", requestID: "r2"))
        guard case .pmBinding(let b) = bound else { return XCTFail("expected binding") }
        XCTAssertNil(b.endedAt)

        let listed = try service.handle(.pmTasksList(projectID: pid))
        guard case .pmTasks(let views) = listed else { return XCTFail("expected views") }
        XCTAssertEqual(views.first?.task.id, task.id)
        XCTAssertEqual(views.first?.task.lifecycle, .inProgress)
        XCTAssertEqual(views.first?.activity, .paused)  // сессия неизвестна демону-тесту
        XCTAssertTrue(events.contains { $0.type == "task.lifecycle_changed" || $0.type == "task.updated" })
        XCTAssertTrue(events.contains { $0.type == "session.bound" })
    }

    func testRequestIDReplayReturnsOriginalResult() throws {
        let pid = try makeProject()
        let first = try service.handle(.pmTasksCreate(projectID: pid, title: "A", body: nil,
                                                      assignee: nil, idleThresholdS: nil,
                                                      requestID: "same-id"))
        let replayed = try service.handle(.pmTasksCreate(projectID: pid, title: "A", body: nil,
                                                         assignee: nil, idleThresholdS: nil,
                                                         requestID: "same-id"))
        XCTAssertEqual(first, replayed)   // Review Focus №2: один результат, не две задачи
        let all = try service.handle(.pmTasksList(projectID: pid))
        guard case .pmTasks(let views) = all else { return XCTFail() }
        XCTAssertEqual(views.count, 1)
    }

    func testRequestIDReuseWithDifferentPayloadRefused() throws {
        let pid = try makeProject()
        _ = try service.handle(.pmTasksCreate(projectID: pid, title: "A", body: nil,
                                              assignee: nil, idleThresholdS: nil, requestID: "x"))
        let result = try service.handle(.pmTasksCreate(projectID: pid, title: "OTHER", body: nil,
                                                       assignee: nil, idleThresholdS: nil, requestID: "x"))
        guard case .error(let code, _) = result else { return XCTFail("expected error") }
        XCTAssertEqual(code, "pmRequestIdReused")   // Review Focus №2
    }

    func testStaleRevisionMapsToErrorCode() throws {
        let pid = try makeProject()
        _ = try service.handle(.pmTasksCreate(projectID: pid, title: "A", body: nil,
                                              assignee: nil, idleThresholdS: nil, requestID: "r"))
        let listed = try service.handle(.pmTasksList(projectID: pid))
        guard case .pmTasks(let views) = listed, let t = views.first?.task else { return XCTFail() }
        _ = try service.handle(.pmTasksUpdate(id: t.id, title: "A2", body: nil,
                                              idleThresholdS: nil, expectedRevision: t.revision,
                                              requestID: "r2"))
        let stale = try service.handle(.pmTasksUpdate(id: t.id, title: "A3", body: nil,
                                                      idleThresholdS: nil,
                                                      expectedRevision: t.revision,
                                                      requestID: "r3"))
        guard case .error(let code, _) = stale else { return XCTFail("expected error") }
        XCTAssertEqual(code, "pmStale")
    }

    func testSessionAddedResolvesExternalSessionID() throws {
        // Пересобираем сервис с резолвером (как main.swift для Claude)
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let bindings = BindingService(db: db, taskStore: tasks)
        let service = PMService(db: db, projects: projects, tasks: tasks, bindings: bindings,
                                rollups: RollupService(db: db, loadBuckets: { [] },
                                    loadBindings: { [] }, externalKeys: { [:] },
                                    projectOfSession: { _ in nil }),
                                analytics: AnalyticsQuery(db: db, prices: []),
                                resolveExternal: { session in
                                    session.resumeCmd == nil ? nil : "uuid-\(session.name)"
                                },
                                now: { 1000 })
        guard case .pmProjects(let plist) = try service.handle(
                .pmProjectsRegister(rootPath: "/dev/\(UUID().uuidString.prefix(6))")),
              let project = plist.first,
              case .pmTask(let task) = try service.handle(.pmTasksCreate(
                projectID: project.id, title: "T", body: nil, assignee: nil,
                idleThresholdS: nil, requestID: "c")),
              case .pmBinding = try service.handle(.pmTasksBind(
                taskID: task.id, session: "s1", requestID: "b"))
        else { return XCTFail("setup failed") }
        var s = Session(name: "s1", dir: "/x", cwd: "/x", agent: "claude", created: 0)
        s.resumeCmd = "claude --resume abc"
        service.sessionAdded(s)
        // q.async внутри sessionAdded — дождаться применения (handle синхронизирует очередь)
        _ = try service.handle(.pmTasksList(projectID: nil))
        XCTAssertEqual(try bindings.externalSessionMap()["s1"], ["uuid-s1"])
    }

    /// Review finding 3: привязка УЖЕ работающей сессии тоже обязана
    /// фиксировать external_session_id (sessionAdded был раньше привязки).
    func testManualBindResolvesExternalSessionID() throws {
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let bindings = BindingService(db: db, taskStore: tasks)
        let live = Session(name: "s-live", dir: "/x", cwd: "/x", agent: "claude", created: 0,
                           resumeCmd: "claude --resume live-uuid")
        let service = PMService(db: db, projects: projects, tasks: tasks, bindings: bindings,
                                rollups: RollupService(db: db, loadBuckets: { [] },
                                    loadBindings: { [] }, externalKeys: { [:] },
                                    projectOfSession: { _ in nil }),
                                analytics: AnalyticsQuery(db: db, prices: []),
                                resolveExternal: { session in
                                    session.resumeCmd == nil ? nil : "uuid-\(session.name)"
                                },
                                sessionByName: { name in name == live.name ? live : nil },
                                now: { 1000 })
        guard case .pmProjects(let plist) = try service.handle(
                .pmProjectsRegister(rootPath: "/dev/\(UUID().uuidString.prefix(6))")),
              let project = plist.first,
              case .pmTask(let task) = try service.handle(.pmTasksCreate(
                projectID: project.id, title: "T", body: nil, assignee: nil,
                idleThresholdS: nil, requestID: "c"))
        else { return XCTFail("setup failed") }
        _ = try service.handle(.pmTasksBind(taskID: task.id, session: "s-live", requestID: "b"))
        _ = try service.handle(.pmTasksList(projectID: nil))   // дождаться q
        XCTAssertEqual(try bindings.externalSessionMap()["s-live"], ["uuid-s-live"])
    }

    /// Review finding 7: восстановление после порчи БД видно событием.
    func testRecoveryEmitsEvent() throws {
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let service = PMService(db: db, projects: projects, tasks: tasks,
                                bindings: BindingService(db: db, taskStore: tasks),
                                rollups: RollupService(db: db, loadBuckets: { [] },
                                    loadBindings: { [] }, externalKeys: { [:] },
                                    projectOfSession: { _ in nil }),
                                analytics: AnalyticsQuery(db: db, prices: []),
                                recoveryNote: "pm.db was corrupt; started fresh",
                                now: { 1000 })
        var seen: [PMEventEnvelope] = []
        service.onEvent = { seen.append($0) }
        service.start(liveSessions: [], statuses: [:])
        _ = try service.handle(.pmTasksList(projectID: nil))   // дождаться q
        XCTAssertTrue(seen.contains { $0.type == "pm.recovered" })
    }

    /// Review finding 8: пауза по стеночным часам без нового события статуса.
    func testActivityTickFlipsToPausedOnWallClock() throws {
        var nowVal: Int64 = 1000
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let service = PMService(db: db, projects: projects, tasks: tasks,
                                bindings: BindingService(db: db, taskStore: tasks),
                                rollups: RollupService(db: db, loadBuckets: { [] },
                                    loadBindings: { [] }, externalKeys: { [:] },
                                    projectOfSession: { _ in nil }),
                                analytics: AnalyticsQuery(db: db, prices: []),
                                now: { nowVal })
        var seen: [PMEventEnvelope] = []
        service.onEvent = { seen.append($0) }
        guard case .pmProjects(let plist) = try service.handle(
                .pmProjectsRegister(rootPath: "/dev/\(UUID().uuidString.prefix(6))")),
              let project = plist.first,
              case .pmTask(let task) = try service.handle(.pmTasksCreate(
                projectID: project.id, title: "T", body: nil, assignee: nil,
                idleThresholdS: 900, requestID: "c"))
        else { return XCTFail("setup failed") }
        _ = try service.handle(.pmTasksBind(taskID: task.id, session: "s1", requestID: "b"))
        service.onStatus(name: "s1", status: .running, now: nowVal)   // работала
        service.onStatus(name: "s1", status: .idle, now: nowVal)      // замолчала
        _ = try service.handle(.pmTasksList(projectID: nil))
        XCTAssertEqual(seen.last(where: { $0.type == "task.activity_changed" })?.value, "active")
        nowVal += 901   // порог 900с истёк, новых событий статуса нет
        service.tickActivities()
        _ = try service.handle(.pmTasksList(projectID: nil))   // дренировать q
        XCTAssertEqual(seen.last(where: { $0.type == "task.activity_changed" })?.value, "paused")
    }

    /// Review finding 10: reopen без живых привязок → ready (spec §7.1).
    func testReopenWithoutBindingsGoesReady() throws {
        let projects = ProjectStore(db: db)
        let tasks = TaskStore(db: db)
        let service = PMService(db: db, projects: projects, tasks: tasks,
                                bindings: BindingService(db: db, taskStore: tasks),
                                rollups: RollupService(db: db, loadBuckets: { [] },
                                    loadBindings: { [] }, externalKeys: { [:] },
                                    projectOfSession: { _ in nil }),
                                analytics: AnalyticsQuery(db: db, prices: []),
                                now: { 1000 })
        guard case .pmProjects(let plist) = try service.handle(
                .pmProjectsRegister(rootPath: "/dev/\(UUID().uuidString.prefix(6))")),
              let project = plist.first,
              case .pmTask(let task) = try service.handle(.pmTasksCreate(
                projectID: project.id, title: "T", body: nil, assignee: nil,
                idleThresholdS: nil, requestID: "c")),
              case .pmTask = try service.handle(.pmTasksSetStatus(
                id: task.id, lifecycle: "done", expectedRevision: task.revision,
                requestID: "d"))
        else { return XCTFail("setup failed") }
        // done → «reopen» (in_progress от человека) без привязок = ready
        let reopened = try service.handle(.pmTasksSetStatus(
            id: task.id, lifecycle: "in_progress", expectedRevision: task.revision + 1,
            requestID: "r"))
        guard case .pmTask(let after) = reopened else { return XCTFail() }
        XCTAssertEqual(after.lifecycle, .ready)
    }
}
