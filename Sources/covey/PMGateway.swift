import Foundation
import CoveyKit

/// Тонкая абстракция над IPC для тестируемости GUI-логики (фейк в тестах).
protocol PMGateway: AnyObject {
    func projectsList() async throws -> [PMProject]
    func register(rootPath: String) async throws -> PMProject
    func rename(id: String, to: String, expectedRevision: Int64) async throws
    func archive(id: String, archived: Bool, expectedRevision: Int64) async throws
    func reorder(ids: [String]) async throws
    func tasksCreate(projectID: String, title: String, body: String?,
                     assignee: String?, idleThresholdS: Int?) async throws -> PMTask
    func taskUpdate(id: String, title: String?, body: String?, idleThresholdS: Int?,
                    expectedRevision: Int64) async throws -> PMTask
    func taskSetStatus(id: String, lifecycle: PMTaskLifecycle,
                       expectedRevision: Int64) async throws -> PMTask
    func tasksList(projectID: String?) async throws -> [PMTaskView]
    func bind(taskID: String, session: String) async throws -> PMBinding
    func unbind(bindingID: String) async throws
    func spawn(taskID: String) async throws -> PMBinding
    func analytics(projectID: String?, taskID: String?,
                   rangeDays: Int?) async throws -> PMAnalyticsResult
}

/// Производственная реализация поверх IPCClient.
final class IPCPMGateway: PMGateway {
    let client: IPCClient
    init(client: IPCClient) { self.client = client }

    func projectsList() async throws -> [PMProject] { try await client.pmProjectsList() }
    func register(rootPath: String) async throws -> PMProject {
        let list = try await client.pmProjectsRegister(rootPath: rootPath)
        guard let project = list.first else {
            throw IPCClientError.daemonError(code: "pmNotFound", message: "no project returned")
        }
        return project
    }
    func rename(id: String, to: String, expectedRevision: Int64) async throws {
        try await client.pmProjectsRename(id: id, name: to, expectedRevision: expectedRevision)
    }
    func archive(id: String, archived: Bool, expectedRevision: Int64) async throws {
        try await client.pmProjectsArchive(id: id, archived: archived, expectedRevision: expectedRevision)
    }
    func reorder(ids: [String]) async throws { try await client.pmProjectsReorder(ids: ids) }
    func tasksCreate(projectID: String, title: String, body: String?, assignee: String?,
                     idleThresholdS: Int?) async throws -> PMTask {
        try await client.pmTasksCreate(projectID: projectID, title: title, body: body,
                                       assignee: assignee, idleThresholdS: idleThresholdS)
    }
    func taskUpdate(id: String, title: String?, body: String?, idleThresholdS: Int?,
                    expectedRevision: Int64) async throws -> PMTask {
        try await client.pmTasksUpdate(id: id, title: title, body: body,
                                       idleThresholdS: idleThresholdS, expectedRevision: expectedRevision)
    }
    func taskSetStatus(id: String, lifecycle: PMTaskLifecycle,
                       expectedRevision: Int64) async throws -> PMTask {
        try await client.pmTasksSetStatus(id: id, lifecycle: lifecycle, expectedRevision: expectedRevision)
    }
    func tasksList(projectID: String?) async throws -> [PMTaskView] {
        try await client.pmTasksList(projectID: projectID)
    }
    func bind(taskID: String, session: String) async throws -> PMBinding {
        try await client.pmTasksBind(taskID: taskID, session: session)
    }
    func unbind(bindingID: String) async throws { try await client.pmTasksUnbind(bindingID: bindingID) }
    func spawn(taskID: String) async throws -> PMBinding { try await client.pmTasksSpawn(taskID: taskID) }
    func analytics(projectID: String?, taskID: String?,
                   rangeDays: Int?) async throws -> PMAnalyticsResult {
        try await client.pmAnalytics(projectID: projectID, taskID: taskID, rangeDays: rangeDays)
    }
}
