import Foundation

public struct PMTokenTotals: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheCreation: Double
    public var cacheRead: Double
    public var activeMinutes: Int
    public init(input: Double = 0, output: Double = 0, cacheCreation: Double = 0,
                cacheRead: Double = 0, activeMinutes: Int = 0) {
        self.input = input; self.output = output
        self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
        self.activeMinutes = activeMinutes
    }
    public var isEmpty: Bool { input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 && activeMinutes == 0 }
}

public struct PMModelStat: Codable, Equatable, Sendable {
    public var model: String
    public var tokens: PMTokenTotals
    /// nil — модель без цены в прайс-листе.
    public var costUSD: Double?
    public var tasksDone: Int
    public var tasksFailed: Int
    public init(model: String, tokens: PMTokenTotals, costUSD: Double?,
                tasksDone: Int, tasksFailed: Int) {
        self.model = model; self.tokens = tokens; self.costUSD = costUSD
        self.tasksDone = tasksDone; self.tasksFailed = tasksFailed
    }
}

public struct PMProjectAnalytics: Codable, Equatable, Sendable {
    /// nil — глобальный дашборд по всем проектам.
    public var projectID: String?
    /// lifecycle → число задач (без archived).
    public var taskCounts: [String: Int]
    public var totals: PMTokenTotals
    /// nil, если хоть одна модель не оценена (см. allModelsPriced).
    public var costUSD: Double?
    public var allModelsPriced: Bool
    public var byModel: [PMModelStat]
    public var tasksDone: Int
    public var tasksFailed: Int
    public init(projectID: String?, taskCounts: [String: Int], totals: PMTokenTotals,
                costUSD: Double?, allModelsPriced: Bool, byModel: [PMModelStat],
                tasksDone: Int, tasksFailed: Int) {
        self.projectID = projectID; self.taskCounts = taskCounts; self.totals = totals
        self.costUSD = costUSD; self.allModelsPriced = allModelsPriced
        self.byModel = byModel; self.tasksDone = tasksDone; self.tasksFailed = tasksFailed
    }
}

public struct PMTaskTimelineEntry: Codable, Equatable, Sendable {
    public var bindingID: String
    public var coveySession: String
    public var startedAt: Int64
    public var endedAt: Int64?
    /// Доминирующая модель интервала (max output); nil — телеметрии не было.
    public var model: String?
    public var tokens: PMTokenTotals
    public var costUSD: Double?
    public init(bindingID: String, coveySession: String, startedAt: Int64,
                endedAt: Int64?, model: String?, tokens: PMTokenTotals, costUSD: Double?) {
        self.bindingID = bindingID; self.coveySession = coveySession
        self.startedAt = startedAt; self.endedAt = endedAt
        self.model = model; self.tokens = tokens; self.costUSD = costUSD
    }
}

public struct PMAnalyticsResult: Codable, Equatable, Sendable {
    public var project: PMProjectAnalytics?
    public var taskTimeline: [PMTaskTimelineEntry]
    public init(project: PMProjectAnalytics?, taskTimeline: [PMTaskTimelineEntry]) {
        self.project = project
        self.taskTimeline = taskTimeline
    }
}
