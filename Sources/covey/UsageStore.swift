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
    /// Test seam: nil → system notifications, exactly as before the refactor.
    var alertSink: (([LimitAlert]) -> Void)?

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
        // Sonnet's 7d window is deliberately absent: chip-only, no alerts.
        runAlerts(agent: "Claude",
                  windows: [("5h", usage.fiveHour), ("7d", usage.sevenDay)],
                  notified: readMarkers(), now: Date())
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

    // MARK: - Codex app-server lifecycle (moved verbatim from AppModel)

    private var codexServer: CodexAppServer?
    /// Test seam: true between spawn and termination, without touching a real
    /// subprocess (resolveCodexPath may find nothing in a test environment).
    private(set) var codexServerActive = false

    /// Spawn codex app-server if the binary resolves; wire snapshots/state in.
    /// No binary → stays `.stopped`, chip empty. Passive-only.
    func startCodexServerIfNeeded() {
        guard codexUsageEnabled, codexServer == nil, let path = resolveCodexPath() else { return }
        let server = CodexAppServer()
        server.onState = { [weak self] state in self?.setCodexState(state) }
        server.onRateLimits = { [weak self] snap in self?.ingestRateLimits(snap) }
        codexServer = server
        codexServerActive = true
        server.start(codexPath: path)
    }

    func setCodexState(_ state: CodexServerState) {
        codexState = state
        if case .stopped = state { codexServerActive = false }
        switch state {
        case .active(let acc):
            codexPlan = codexPlanLabel(acc.planType)
        case .unauthed:
            // A different (non-chatgpt) account really has no data — unlike
            // .stopped/.starting this isn't a transient gap, so the cache
            // does not carry over.
            codexPlan = nil
            codexUsage = nil
        case .stopped, .starting:
            break   // keep the last-known cache; server down != data invalid
        }
    }

    /// Merge a (possibly partial) Codex snapshot into the live one, then run
    /// the same 80%-alert machinery as Claude under the "codex" marker prefix.
    func ingestRateLimits(_ update: CodexRateLimitsSnapshot, now: Date = Date()) {
        codexUsage = mergeCodex(into: codexUsage, update: update)
        onPersist()
        guard let usage = codexUsage else { return }
        let windows: [(key: String, window: UsageWindow?)] =
            usage.windows.map { ($0.label, $0.window) }
        runAlerts(agent: "Codex", windows: windows,
                  notified: readMarkers(), now: now)
    }

    /// Shared 80%-crossing detection for both agents: dedup via the persisted
    /// marker map, deliver via alertSink (system notifier by default).
    private func runAlerts(agent: String,
                           windows: [(key: String, window: UsageWindow?)],
                           notified: [String: Int64], now: Date) {
        let (alerts, marks) = limitAlerts(agent: agent, windows: windows,
                                          notified: notified, now: now)
        if let alertSink { alertSink(alerts) }
        else { for alert in alerts { Notifier.post(alert) } }
        if marks != notified {
            writeMarkers(marks)
            onPersist()
        }
    }

    /// Toggle-driven: spawn when enabled, tear down when not.
    func synchronizeCodexServer() {
        if codexUsageEnabled {
            startCodexServerIfNeeded()
        } else {
            stopCodexServer()
            codexState = .stopped
        }
    }

    func stopCodexServer() {
        codexServer?.stop()
        codexServer = nil
        codexServerActive = false
    }
}
