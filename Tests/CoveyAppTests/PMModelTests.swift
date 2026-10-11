import XCTest
import CoveyKit
@testable import covey

final class PMModelTests: XCTestCase {
    /// Фейковый шлюз: записывает вызовы, возвращает заготовки.
    final class FakeGateway: PMGateway {
        var bound: [(task: String, session: String)] = []
        var listed: [PMTaskView] = []
        func projectsList() async throws -> [PMProject] { [] }
        func register(rootPath: String) async throws -> PMProject {
            PMProject(id: "p1", rootPath: rootPath, name: "x", sortOrder: 0, createdAt: 0)
        }
        func rename(id: String, to: String, expectedRevision: Int64) async throws {}
        func archive(id: String, archived: Bool, expectedRevision: Int64) async throws {}
        func reorder(ids: [String]) async throws {}
        func tasksCreate(projectID: String, title: String, body: String?,
                         assignee: String?, idleThresholdS: Int?) async throws -> PMTask {
            PMTask(id: "t1", projectID: projectID, title: title, body: body ?? "",
                   revision: 1, createdAt: 0, updatedAt: 0)
        }
        func taskUpdate(id: String, title: String?, body: String?, idleThresholdS: Int?,
                        expectedRevision: Int64) async throws -> PMTask {
            PMTask(id: id, projectID: "p1", title: title ?? "t", body: body ?? "",
                   revision: expectedRevision + 1, createdAt: 0, updatedAt: 1)
        }
        func taskSetStatus(id: String, lifecycle: PMTaskLifecycle,
                           expectedRevision: Int64) async throws -> PMTask {
            PMTask(id: id, projectID: "p1", title: "t", body: "", lifecycle: lifecycle,
                   revision: expectedRevision + 1, createdAt: 0, updatedAt: 1, closedAt: 1)
        }
        func tasksList(projectID: String?) async throws -> [PMTaskView] { listed }
        func bind(taskID: String, session: String) async throws -> PMBinding {
            bound.append((taskID, session))
            return PMBinding(id: "b1", taskID: taskID, coveySession: session, startedAt: 0)
        }
        func unbind(bindingID: String) async throws {}
        func spawn(taskID: String) async throws -> PMBinding {
            PMBinding(id: "b2", taskID: taskID, coveySession: "new", startedAt: 0)
        }
        func analytics(projectID: String?, taskID: String?,
                       rangeDays: Int?) async throws -> PMAnalyticsResult {
            PMAnalyticsResult(project: nil, taskTimeline: [])
        }
    }

    @MainActor
    func testEventDedupAndActivityUpdate() async throws {
        let model = PMModel()
        let gw = FakeGateway()
        model.install(gateway: gw)
        let task = PMTask(id: "t1", projectID: "p1", title: "T", body: "",
                          lifecycle: .inProgress, revision: 2, createdAt: 0, updatedAt: 0)
        model.tasksByProject["p1"] = [PMTaskView(task: task, activity: .active, openBindings: [])]
        let env = PMEventEnvelope(eventID: "e1", seq: 1, entityID: "t1",
                                  entityRevision: 2, type: "task.activity_changed",
                                  value: "paused", occurredAt: 0)
        model.apply(env)
        XCTAssertEqual(model.tasksByProject["p1"]?.first?.activity, .paused) // значение из envelope
        model.apply(env)   // дубликат eventID — не должен сломать состояние
        XCTAssertEqual(model.tasksByProject["p1"]?.first?.activity, .paused)
        XCTAssertEqual(model.appliedEventCount, 1)
    }

    @MainActor
    func testTaskEventMarksStale() async throws {
        let model = PMModel()
        model.install(gateway: FakeGateway())
        let task = PMTask(id: "t1", projectID: "p1", title: "T", body: "",
                          lifecycle: .inProgress, revision: 5, createdAt: 0, updatedAt: 0)
        model.tasksByProject["p1"] = [PMTaskView(task: task, activity: .active, openBindings: [])]
        let changed = PMEventEnvelope(eventID: "e2", seq: 2, entityID: "t1",
                                      entityRevision: 3, type: "task.lifecycle_changed",
                                      occurredAt: 0)
        model.apply(changed)
        // Точный тип изменений не восстанавливаем — задача помечена на перечитывание
        XCTAssertTrue(model.staleTaskIDs.contains("t1"))
        XCTAssertFalse(model.tasksByProject["p1"]!.isEmpty)  // локальный кэш не снесён
    }

    @MainActor
    func testBindCallsGateway() async throws {
        let model = PMModel()
        let gw = FakeGateway()
        model.install(gateway: gw)
        try await model.bind(taskID: "t1", session: "s9")
        XCTAssertEqual(gw.bound.first?.session, "s9")
    }
}
