import Foundation

public enum PMTaskLifecycle: String, Codable, Equatable, Sendable {
    case ready, inProgress = "in_progress"
    case done, failed, cancelled, archived
}

public enum PMActivity: String, Codable, Equatable, Sendable {
    case active, paused, idle
}

public struct PMProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var rootPath: String
    public var name: String
    public var sortOrder: Int
    public var archivedAt: Int64?
    public var revision: Int64
    public var createdAt: Int64
    /// Вычисляется демоном при list (корня нет на диске); не хранится.
    public var missing: Bool?
    public init(id: String, rootPath: String, name: String, sortOrder: Int,
                archivedAt: Int64? = nil, revision: Int64 = 1, createdAt: Int64,
                missing: Bool? = nil) {
        self.id = id; self.rootPath = rootPath; self.name = name
        self.sortOrder = sortOrder; self.archivedAt = archivedAt
        self.revision = revision; self.createdAt = createdAt; self.missing = missing
    }
}

public struct PMTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var projectID: String
    public var title: String
    public var body: String
    /// implementation | fix | experiment | conflict_resolution (ТЗ).
    public var kind: String
    public var lifecycle: PMTaskLifecycle
    /// agent | human.
    public var assignee: String
    /// Секунды; nil = default из настроек (900).
    public var idleThresholdSeconds: Int?
    public var revision: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
    public var closedAt: Int64?
    public init(id: String, projectID: String, title: String, body: String,
                kind: String = "implementation", lifecycle: PMTaskLifecycle = .ready,
                assignee: String = "agent", idleThresholdSeconds: Int? = nil,
                revision: Int64 = 1, createdAt: Int64, updatedAt: Int64,
                closedAt: Int64? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.body = body
        self.kind = kind; self.lifecycle = lifecycle; self.assignee = assignee
        self.idleThresholdSeconds = idleThresholdSeconds
        self.revision = revision; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.closedAt = closedAt
    }
}

/// Одна привязка сессии к задаче = интервал (spec §7.3).
public struct PMBinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: String
    public var coveySession: String
    /// provider sessionId == TokenEvent.sessionKey; фиксируется при первом токен-событии.
    public var externalSessionID: String?
    public var provider: String?
    public var startedAt: Int64
    public var endedAt: Int64?
    public init(id: String, taskID: String, coveySession: String,
                externalSessionID: String? = nil, provider: String? = nil,
                startedAt: Int64, endedAt: Int64? = nil) {
        self.id = id; self.taskID = taskID; self.coveySession = coveySession
        self.externalSessionID = externalSessionID; self.provider = provider
        self.startedAt = startedAt; self.endedAt = endedAt
    }
    public func covers(_ ms: Int64) -> Bool {
        ms >= startedAt * 1000 && (endedAt == nil || ms < endedAt! * 1000)
    }
}

/// Строка tasks.list: задача + производная активность + открытые привязки.
public struct PMTaskView: Codable, Equatable, Sendable, Identifiable {
    public var task: PMTask
    public var activity: PMActivity
    public var openBindings: [PMBinding]
    /// Идентичность строки — идентичность задачи.
    public var id: String { task.id }
    public init(task: PMTask, activity: PMActivity, openBindings: [PMBinding]) {
        self.task = task; self.activity = activity; self.openBindings = openBindings
    }
}

public enum PMTaskTransitions {
    /// Автопереход при bind/spawn: ready → in_progress; иначе nil.
    public static func autoOnBind(_ from: PMTaskLifecycle) -> PMTaskLifecycle? {
        from == .ready ? .inProgress : nil
    }
    /// Терминальные/реопен/архив — только человек (spec §7.1). Reopen в
    /// in_progress разрешён при живых привязках; PMService мапит его в ready,
    /// когда привязок нет — поэтому ready здесь тоже легальная цель.
    public static func human(_ from: PMTaskLifecycle, _ to: PMTaskLifecycle) -> Bool {
        switch (from, to) {
        case (.ready, .done), (.ready, .failed), (.ready, .cancelled),
             (.inProgress, .done), (.inProgress, .failed), (.inProgress, .cancelled),
             (.inProgress, .archived),
             (.done, .archived), (.failed, .archived), (.cancelled, .archived),
             (.done, .inProgress), (.failed, .inProgress), (.cancelled, .inProgress),
             (.done, .ready), (.failed, .ready), (.cancelled, .ready):
            return true
        default:
            return false
        }
    }
}

/// Конверт события PM (ТЗ §22.6, spec §5.3). seq монотонен в рамках запуска
/// демона; GUI дедуплицирует по eventID и не применяет старую ревизию.
public struct PMEventEnvelope: Codable, Equatable, Sendable {
    public var eventID: String
    public var seq: Int64
    public var entityID: String
    public var entityRevision: Int64?
    public var type: String
    /// Новое значение для производных событий: rawValue PMActivity для
    /// task.activity_changed. nil для остальных типов.
    public var value: String?
    public var occurredAt: Int64
    public init(eventID: String, seq: Int64, entityID: String,
                entityRevision: Int64? = nil, type: String,
                value: String? = nil, occurredAt: Int64) {
        self.eventID = eventID; self.seq = seq; self.entityID = entityID
        self.entityRevision = entityRevision; self.type = type
        self.value = value; self.occurredAt = occurredAt
    }
}

/// Порог простоя per-task: "30m" / "2h" / "3d" (spec D3).
public enum PMIdleThreshold {
    public static let defaultSeconds = 900
    public static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = t.last, t.count >= 2,
              let n = Int(t.dropLast()), n > 0 else { return nil }
        switch last {
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86_400
        default: return nil
        }
    }
    public static func format(_ seconds: Int) -> String {
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
