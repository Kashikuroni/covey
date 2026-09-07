import Foundation

/// Codex app-server connection state.
public enum CodexServerState: Codable, Equatable, Sendable {
    case stopped
    case starting
    case unauthed                 // not a chatgpt account → no chip
    case active(CodexAccount)
}

public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex
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
    public init() {}
}
