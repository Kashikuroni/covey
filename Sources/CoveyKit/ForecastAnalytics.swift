import Foundation

public enum ForecastUsageSource: String, Codable, Equatable, Sendable {
    case claudeCode
    case codex
}

public struct ForecastSessionIdentity: Equatable, Sendable {
    public var sourceID: String?
    public var name: String
    public var cwd: String
    public var agent: String
    public var created: Int64
    public var providerID: String?

    public init(sourceID: String? = nil, name: String, cwd: String,
                agent: String, created: Int64, providerID: String? = nil) {
        self.sourceID = sourceID
        self.name = name
        self.cwd = cwd
        self.agent = agent
        self.created = created
        self.providerID = providerID
    }
}

public struct ForecastSessionMetadata: Codable, Equatable, Sendable {
    public var source: ForecastUsageSource
    public var cwd: String?
    public var external: Bool

    public init(source: ForecastUsageSource, cwd: String? = nil, external: Bool) {
        self.source = source
        self.cwd = cwd
        self.external = external
    }
}

public struct ForecastSessionUsage: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var source: ForecastUsageSource
    public var external: Bool
    public var active: Bool
    public var tokensPerHour: Double
    public var cacheHit: Double?
    public var contextTokens: Double?
    public var contextDeltaPerTurn: Double?
    public var creditsPerHour: Double?
    public var budgetMinutes: Double?

    public init(id: String, name: String, source: ForecastUsageSource,
                external: Bool, active: Bool, tokensPerHour: Double,
                cacheHit: Double? = nil, contextTokens: Double? = nil,
                contextDeltaPerTurn: Double? = nil,
                creditsPerHour: Double? = nil, budgetMinutes: Double? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.external = external
        self.active = active
        self.tokensPerHour = tokensPerHour
        self.cacheHit = cacheHit
        self.contextTokens = contextTokens
        self.contextDeltaPerTurn = contextDeltaPerTurn
        self.creditsPerHour = creditsPerHour
        self.budgetMinutes = budgetMinutes
    }
}

public struct ForecastSessionCostEntry: Codable, Equatable, Sendable {
    public var record: SessionCostRecord
    public var name: String
    public var source: ForecastUsageSource
    public var live: Bool

    public init(record: SessionCostRecord, name: String,
                source: ForecastUsageSource, live: Bool) {
        self.record = record
        self.name = name
        self.source = source
        self.live = live
    }
}

public struct ForecastAnalytics: Codable, Equatable, Sendable {
    public var models: [GLMModelUsage]
    public var modelDaily: [GLMDayUsage]
    public var hourly: [GLMSeriesPoint]
    public var modelHourly: [GLMHourUsage]
    public var sessions: [ForecastSessionUsage]
    public var sessionCosts: [ForecastSessionCostEntry]

    public init(models: [GLMModelUsage] = [],
                modelDaily: [GLMDayUsage] = [],
                hourly: [GLMSeriesPoint] = [],
                modelHourly: [GLMHourUsage] = [],
                sessions: [ForecastSessionUsage] = [],
                sessionCosts: [ForecastSessionCostEntry] = []) {
        self.models = models
        self.modelDaily = modelDaily
        self.hourly = hourly
        self.modelHourly = modelHourly
        self.sessions = sessions
        self.sessionCosts = sessionCosts
    }
}
