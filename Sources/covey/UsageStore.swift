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
    // `persisted` is a struct AppModel reassigns wholesale in start(), so
    // marker access goes through closures over its current value.
    private let readMarkers: () -> [String: Int64]
    private let writeMarkers: ([String: Int64]) -> Void
    private var usagePoller: Task<Void, Never>?
    private var glmUsagePoller: Task<Void, Never>?

    init(fetchAccount: @escaping () async -> Account = { Account() },
         fetchGlmAccount: @escaping () async -> Account = { Account() },
         usageInterval: TimeInterval = 60,
         onPersist: @escaping () -> Void = {},
         readMarkers: @escaping () -> [String: Int64] = { [:] },
         writeMarkers: @escaping ([String: Int64]) -> Void = { _ in }) {
        self.fetchAccount = fetchAccount
        self.fetchGlmAccount = fetchGlmAccount
        self.usageInterval = usageInterval
        self.onPersist = onPersist
        self.readMarkers = readMarkers
        self.writeMarkers = writeMarkers
    }

    /// One Claude poll cycle: usage and plan come from two independent API
    /// calls — each only replaces the cache on its own success, so a transient
    /// failure of either never blanks out the other's last known value.
    func tickClaude() async {
        guard claudeUsageEnabled else { return }
        let acc = await fetchAccount()
        var changed = false
        if let newUsage = acc.usage { usage = newUsage; changed = true }
        if let newPlan = acc.plan { plan = newPlan; changed = true }
        if changed { onPersist() }
        usageError = acc.usageError
        if let err = acc.usageError {
            UsageLog.note("claude", [("ev", "tick"), ("err", err)])
        }
        // Failed fetch (nil usage) must not touch alert markers: the
        // current window's dedup survives network gaps.
        guard let usage = acc.usage else { return }
        let old = readMarkers()
        // Sonnet's 7d window is deliberately absent: chip-only, no alerts.
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: [("5h", usage.fiveHour), ("7d", usage.sevenDay)],
            notified: old, now: Date())
        for alert in alerts { Notifier.post(alert) }
        if marks != old {
            writeMarkers(marks)
            onPersist()
        }
    }

    /// GLM's poll: usage-only (no plan, no window alerts — those are Claude's
    /// 5h/7d alerting, out of scope for the read-only 5h token gauge here).
    func tickGlm() async {
        guard glmUsageEnabled else { return }
        let acc = await fetchGlmAccount()
        var changed = false
        if let newUsage = acc.usage { glmUsage = newUsage; changed = true }
        if changed { onPersist() }
        glmUsageError = acc.usageError
        if let err = acc.usageError, err != glmUsageError {
            UsageLog.note("glm", [("ev", "tick"), ("err", err)])
        }
    }

    /// Re-read usage every `usageInterval` until stopped (was two inline
    /// AppModel tasks in start()).
    func startPolling() {
        usagePoller?.cancel()
        usagePoller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickClaude()
                try? await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000))
            }
        }
        glmUsagePoller?.cancel()
        glmUsagePoller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickGlm()
                try? await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        usagePoller?.cancel()
        glmUsagePoller?.cancel()
        usagePoller = nil
        glmUsagePoller = nil
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
