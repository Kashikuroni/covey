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
    }
}
