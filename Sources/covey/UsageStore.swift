import Foundation
import CoveyKit

/// Owns every usage/limits concern: Claude/GLM poll state, Codex app-server
/// lifecycle, and the 80% alert markers. Extracted from AppModel (which stays
/// the observable facade views read); see docs/superpowers/specs/2026-08-31-
/// usage-store-refactor-design.md.
@MainActor @Observable
final class UsageStore {
    // Internal writable while the tick/codex methods still live in AppModel
    // (Tasks 2–3 move them here); the facade keeps the public surface.
    var usage: Usage?
    var plan: String?
    var usageError: String?
    var glmUsage: Usage?
    var glmUsageError: String?
    var codexUsage: CodexRateLimitsSnapshot?
    var codexPlan: String?
    var codexState: CodexServerState = .stopped

    var claudeUsageEnabled = true
    var codexUsageEnabled = true
    var glmUsageEnabled = true

    private let fetchAccount: () async -> Account
    private let fetchGlmAccount: () async -> Account
    private let usageInterval: TimeInterval
    private let onPersist: () -> Void

    init(fetchAccount: @escaping () async -> Account = { Account() },
         fetchGlmAccount: @escaping () async -> Account = { Account() },
         usageInterval: TimeInterval = 60,
         onPersist: @escaping () -> Void = {}) {
        self.fetchAccount = fetchAccount
        self.fetchGlmAccount = fetchGlmAccount
        self.usageInterval = usageInterval
        self.onPersist = onPersist
    }

    /// Restore the last-known cache from persisted state (was AppModel.start).
    /// Takes the struct by value because AppModel reassigns `persisted` in start().
    func restoreFromPersisted(_ persisted: PersistedState) {
        claudeUsageEnabled = persisted.claudeUsageEnabled ?? true
        codexUsageEnabled = persisted.codexUsageEnabled ?? true
        if let cached = persisted.claudeUsage { usage = cached.live }
        plan = persisted.claudePlan
        if let cached = persisted.codexUsage { codexUsage = cached.live }
        codexPlan = persisted.codexPlan
        glmUsageEnabled = persisted.glmUsageEnabled ?? true
        if let cached = persisted.glmUsage { glmUsage = cached.live }
    }
}
