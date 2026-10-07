import Foundation

/// Codex app-server connection state.
public enum CodexServerState: Codable, Equatable, Sendable {
    case stopped
    case starting
    case unauthed                 // not a chatgpt account → no chip
    case active(CodexAccount)
}

public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex, glm
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var revision: UInt64 = 0
    public var usage: Usage?
    public var plan: String?
    public var usageError: String?
    public var codexUsage: CodexRateLimitsSnapshot?
    public var codexPlan: String?
    public var codexState: CodexServerState = .stopped
    public var claudeUsageEnabled = true
    public var codexUsageEnabled = true
    public var glmQuota: GLMQuota?
    public var glmUsageError: String?
    public var glmUsageEnabled = true
    public var glmForecast: GLMForecast?
    public var forecastAnalytics: ForecastAnalytics?
    /// Прогноз Codex rate-limit окон (этап 2).
    public var codexForecast: CodexForecast?
    public init() {}

    /// Every field is optional on decode so a snapshot written before a
    /// field existed keeps loading (defaults apply); unknown keys — the
    /// retired `glmUsage` cache, for one — stay ignored. Encoding remains
    /// synthesized: nil optionals are omitted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        usageError = try c.decodeIfPresent(String.self, forKey: .usageError)
        codexUsage = try c.decodeIfPresent(CodexRateLimitsSnapshot.self, forKey: .codexUsage)
        codexPlan = try c.decodeIfPresent(String.self, forKey: .codexPlan)
        codexState = try c.decodeIfPresent(CodexServerState.self, forKey: .codexState) ?? .stopped
        claudeUsageEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeUsageEnabled) ?? true
        codexUsageEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexUsageEnabled) ?? true
        glmQuota = try c.decodeIfPresent(GLMQuota.self, forKey: .glmQuota)
        glmUsageError = try c.decodeIfPresent(String.self, forKey: .glmUsageError)
        glmUsageEnabled = try c.decodeIfPresent(Bool.self, forKey: .glmUsageEnabled) ?? true
        glmForecast = try c.decodeIfPresent(GLMForecast.self, forKey: .glmForecast)
        forecastAnalytics = try c.decodeIfPresent(ForecastAnalytics.self,
                                                  forKey: .forecastAnalytics)
            ?? glmForecast.flatMap(ForecastAnalytics.init(legacy:))
        codexForecast = try c.decodeIfPresent(CodexForecast.self, forKey: .codexForecast)
    }
}

private extension ForecastAnalytics {
    init?(legacy forecast: GLMForecast) {
        let modelDaily = forecast.modelDaily ?? []
        let hourly = forecast.hourly ?? []
        let modelHourly = forecast.modelHourly ?? []
        let sessionCosts = forecast.sessionCosts ?? []
        guard !forecast.models.isEmpty || !modelDaily.isEmpty || !hourly.isEmpty
                || !modelHourly.isEmpty || !forecast.agents.isEmpty
                || !sessionCosts.isEmpty else { return nil }

        self.init(
            models: forecast.models,
            modelDaily: modelDaily,
            hourly: hourly,
            modelHourly: modelHourly,
            sessions: forecast.agents.map { agent in
                ForecastSessionUsage(
                    id: agent.stableID,
                    name: agent.name,
                    source: .claudeCode,
                    external: agent.external,
                    active: agent.active,
                    tokensPerHour: agent.tokensPerHour,
                    cacheHit: agent.cacheHit,
                    contextTokens: agent.contextTokens,
                    contextDeltaPerTurn: agent.contextDeltaPerTurn,
                    creditsPerHour: agent.creditsPerHour,
                    budgetMinutes: agent.budgetMinutes)
            },
            sessionCosts: sessionCosts.map { entry in
                ForecastSessionCostEntry(record: entry.record,
                                         name: entry.name,
                                         source: .claudeCode,
                                         live: entry.live)
            })
    }
}
