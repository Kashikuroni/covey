import Foundation
import Observation
import CoveyKit

/// GUI-состояние Project Manager. Один источник правды — демон; модель — кэш
/// + применение событий (дедуп по eventID; события о задаче, кроме
/// activity_changed, — сигнал перечитать: задача помечается грязной).
@MainActor @Observable
final class PMModel {
    var projects: [PMProject] = []
    var tasksByProject: [String: [PMTaskView]] = [:]
    var analytics: PMAnalyticsResult?
    var analyticsRangeDays = 30
    var appliedEventCount = 0
    var staleTaskIDs: Set<String> = []
    private var seenEventIDs: Set<String> = []
    private var gateway: (any PMGateway)?

    func install(gateway: any PMGateway) {
        self.gateway = gateway
    }

    func bootstrap() async {
        guard let gateway else { return }
        projects = (try? await gateway.projectsList()) ?? []
        await reloadAllTasks()
    }

    func reloadAllTasks() async {
        guard let gateway else { return }
        let views = (try? await gateway.tasksList(projectID: nil)) ?? []
        var byProject: [String: [PMTaskView]] = [:]
        for v in views { byProject[v.task.projectID, default: []].append(v) }
        tasksByProject = byProject
        let fresh = Set(views.map(\.task.id))
        staleTaskIDs.formIntersection(fresh)
    }

    func reloadTasks(projectID: String) async {
        guard let gateway else { return }
        tasksByProject[projectID] = (try? await gateway.tasksList(projectID: projectID)) ?? []
    }

    /// Событие демона: дедуп по eventID. activity_changed применяет значение
    /// из envelope; остальные события о задаче — сигнал перечитать (ТЗ §22.6:
    /// событие не заменяет preconditions): задача помечается грязной,
    /// AppModel после apply делает reload.
    func apply(_ env: PMEventEnvelope) {
        guard !seenEventIDs.contains(env.eventID) else { return }
        seenEventIDs.insert(env.eventID)
        appliedEventCount += 1
        switch env.type {
        case "task.activity_changed":
            if let pid = projectOfTask(env.entityID),
               var list = tasksByProject[pid],
               let i = list.firstIndex(where: { $0.task.id == env.entityID }),
               let value = env.value, let activity = PMActivity(rawValue: value) {
                list[i].activity = activity
                tasksByProject[pid] = list
            }
        case "task.lifecycle_changed", "task.updated", "session.bound", "session.unbound":
            staleTaskIDs.insert(env.entityID)
        case "project.changed":
            Task { await reloadProjectsOnly() }
        default:
            break
        }
    }

    func reloadProjectsOnly() async {
        guard let gateway else { return }
        projects = (try? await gateway.projectsList()) ?? []
    }

    private func projectOfTask(_ id: String) -> String? {
        for (pid, list) in tasksByProject where list.contains(where: { $0.task.id == id }) {
            return pid
        }
        return nil
    }

    // MARK: - действия

    func createTask(projectID: String, title: String, body: String = "",
                    assignee: String = "agent", idleThresholdS: Int? = nil) async throws {
        guard let gateway else { return }
        _ = try await gateway.tasksCreate(projectID: projectID, title: title, body: body,
                                          assignee: assignee, idleThresholdS: idleThresholdS)
        await reloadTasks(projectID: projectID)
    }

    func setLifecycle(task: PMTask, to: PMTaskLifecycle) async throws {
        guard let gateway else { return }
        _ = try await gateway.taskSetStatus(id: task.id, lifecycle: to,
                                            expectedRevision: task.revision)
        await reloadTasks(projectID: task.projectID)
    }

    func bind(taskID: String, session: String) async throws {
        guard let gateway else { return }
        _ = try await gateway.bind(taskID: taskID, session: session)
        await reloadAllTasks()
    }

    func spawn(taskID: String) async throws {
        guard let gateway else { return }
        _ = try await gateway.spawn(taskID: taskID)
        await reloadAllTasks()
    }

    func updateTask(id: String, projectID: String, title: String?, body: String?,
                    idleThresholdS: Int?, expectedRevision: Int64) async throws {
        guard let gateway else { return }
        _ = try await gateway.taskUpdate(id: id, title: title, body: body,
                                         idleThresholdS: idleThresholdS,
                                         expectedRevision: expectedRevision)
        await reloadTasks(projectID: projectID)
    }

    // MARK: - реестр проектов (обёртки для AppModel)

    func registerProject(rootPath: String) async {
        guard let gateway else { return }
        _ = try? await gateway.register(rootPath: rootPath)
        await reloadProjectsOnly()
    }

    func archiveProjectRoot(rootPath: String) async {
        guard let gateway,
              let project = projects.first(where: { $0.rootPath == rootPath }) else { return }
        try? await gateway.archive(id: project.id, archived: true,
                                   expectedRevision: project.revision)
        await reloadProjectsOnly()
    }

    func renameProjectRoot(rootPath: String, to name: String) async {
        guard let gateway,
              let project = projects.first(where: { $0.rootPath == rootPath }) else { return }
        try? await gateway.rename(id: project.id, to: name,
                                  expectedRevision: project.revision)
        await reloadProjectsOnly()
    }

    func loadAnalytics(projectID: String?, taskID: String? = nil) async {
        guard let gateway else { return }
        analytics = try? await gateway.analytics(projectID: projectID, taskID: taskID,
                                                 rangeDays: analyticsRangeDays)
    }
}
