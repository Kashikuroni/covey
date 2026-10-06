import Foundation
import CoveyKit

/// Daemon-owned collection and cache. No UI or notification delivery lives here.
@MainActor
public final class UsageMonitor {
    public private(set) var snapshot: UsageSnapshot
    public var onChange: ((UsageSnapshot) -> Void)?
    private let path: String?
    private var persistenceError: Error?
    private let fetchAccount: () async -> Account
    private let fetchGLM: () async -> GLMAccount
    private let usageInterval: TimeInterval
    private let resolveCodex: () -> String?
    private var running = false
    private var pollers: [UsageProvider: Task<Void, Never>] = [:]
    private var generations: [UsageProvider: UInt64] = [:]
    private var requests: [UsageProvider: UInt64] = [:]
    private var codexServer: CodexAppServer?
    // Прогнозная аналитика: стор/агрегатор/вотчеры принадлежат актору,
    // монитор лишь публикует снимки (все nil → прогноз выключен).
    private var forecastMonitor: ForecastAnalyticsMonitor?
    private var forecastSessions: (() -> [ForecastSessionIdentity])?
    private var analyticsTask: Task<Void, Never>?

    public init(path: String? = nil, legacyPath: String? = nil,
                fetchAccount: @escaping () async -> Account = UsageService.fetchAccount,
                fetchGLM: @escaping () async -> GLMAccount = GlmUsageService.fetchGLMAccount,
                usageInterval: TimeInterval = 60,
                resolveCodex: @escaping () -> String? = resolveCodexPath,
                forecastMonitor: ForecastAnalyticsMonitor? = nil,
                forecastSessions: (() -> [ForecastSessionIdentity])? = nil) {
        self.path = path
        self.fetchAccount = fetchAccount
        self.fetchGLM = fetchGLM
        self.usageInterval = max(0.01, usageInterval)
        self.resolveCodex = resolveCodex
        self.forecastMonitor = forecastMonitor
        self.forecastSessions = forecastSessions
        var restored = UsageSnapshot()
        if let path, FileManager.default.fileExists(atPath: path) {
            do { restored = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
            catch { persistenceError = error }
        } else if let legacyPath, FileManager.default.fileExists(atPath: legacyPath) {
            do {
                let legacy = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: URL(fileURLWithPath: legacyPath)))
                restored.usage = legacy.claudeUsage?.live
                restored.plan = legacy.claudePlan
                restored.codexUsage = legacy.codexUsage?.live
                restored.codexPlan = legacy.codexPlan
                restored.claudeUsageEnabled = legacy.claudeUsageEnabled ?? true
                restored.codexUsageEnabled = legacy.codexUsageEnabled ?? true
            } catch { persistenceError = error }
        }
        restored.revision = 0
        restored.codexState = .stopped
        snapshot = restored
        // Import once even when the providers were all disabled in legacy state.
        if let path, !FileManager.default.fileExists(atPath: path), persistenceError == nil {
            do { try persist(restored) } catch { UsageLog.note("persistence", [("err", "\(error)")]) }
        }
        if let persistenceError { UsageLog.note("persistence", [("err", "\(persistenceError)")]) }
    }

    public func start() {
        guard !running else { return }
        running = true
        // Независимый analytics-цикл: 60-секундный тик не зависит от
        // claude/codex/glm поллингов и их переключателей.
        if forecastMonitor != nil {
            analyticsTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshAnalytics()
                    do { try await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000)) }
                    catch { return }
                }
            }
        }
        for provider in UsageProvider.allCases {
            pollers[provider] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if provider == .codex, self.snapshot.codexState != .unauthed {
                        if self.isEnabled(provider) { self.startCodexIfNeeded() }
                    } else {
                        await self.refresh(provider)
                    }
                    do { try await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000)) }
                    catch { return }
                }
            }
        }
    }

    public func stop() {
        running = false
        analyticsTask?.cancel()
        analyticsTask = nil
        for task in pollers.values { task.cancel() }
        pollers.removeAll()
        for provider in UsageProvider.allCases { generations[provider, default: 0] &+= 1 }
        stopCodex()
        if snapshot.codexState != .stopped { mutate { $0.codexState = .stopped } }
    }

    public func setEnabled(_ provider: UsageProvider, enabled: Bool) throws {
        guard isEnabled(provider) != enabled else { return }
        var next = snapshot
        switch provider {
        case .claude: next.claudeUsageEnabled = enabled
        case .codex: next.codexUsageEnabled = enabled; if !enabled { next.codexState = .stopped }
        case .glm: next.glmUsageEnabled = enabled
        }
        next.revision &+= 1
        try persist(next)
        generations[provider, default: 0] &+= 1
        snapshot = next
        onChange?(snapshot)
        if provider == .codex, !enabled { stopCodex() }
        if enabled, running { Task { [weak self] in await self?.refresh(provider) } }
    }

    public func refresh(_ provider: UsageProvider) async {
        guard isEnabled(provider) else { return }
        if provider == .codex {
            if case .active = snapshot.codexState {
                codexServer?.refreshRateLimits()
            } else {
                if snapshot.codexState == .unauthed { stopCodex() }
                startCodexIfNeeded()
            }
            return
        }
        let generation = generations[provider, default: 0]
        requests[provider, default: 0] &+= 1
        let request = requests[provider, default: 0]
        func stillCurrent() -> Bool {
            !Task.isCancelled && isEnabled(provider)
                && generations[provider, default: 0] == generation
                && requests[provider] == request
        }
        switch provider {
        case .claude:
            let account = await fetchAccount()
            guard stillCurrent() else { return }
            mutate {
                if let usage = account.usage { $0.usage = usage }
                if let plan = account.plan { $0.plan = plan }
                $0.usageError = account.usageError
            }
        case .glm:
            let account = await fetchGLM()
            guard stillCurrent() else { return }
            mutate {
                if let quota = account.quota { $0.glmQuota = quota }
                $0.glmUsageError = account.error
            }
            if let quota = account.quota { await updateForecast(quota: quota) }
        case .codex:
            break
        }
    }

    public func ingestRateLimits(_ update: CodexRateLimitsSnapshot) {
        guard snapshot.codexUsageEnabled else { return }
        mutate { $0.codexUsage = mergeCodex(into: $0.codexUsage, update: update) }
    }

    public func setCodexState(_ state: CodexServerState) {
        guard snapshot.codexUsageEnabled else { return }
        if state == .stopped { stopCodex() }
        mutate {
            $0.codexState = state
            switch state {
            case .active(let account): $0.codexPlan = codexPlanLabel(account.planType)
            case .unauthed: $0.codexPlan = nil; $0.codexUsage = nil
            case .stopped, .starting: break
            }
        }
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .claude: return snapshot.claudeUsageEnabled
        case .codex: return snapshot.codexUsageEnabled
        case .glm: return snapshot.glmUsageEnabled
        }
    }

    // MARK: - GLM forecast (спека §4–§7)

    /// Прогноз-цикл успешного GLM-поллинга: весь state — в акторе; монитор
    /// публикует готовую пару (украшенный прогноз, аналитика).
    private func updateForecast(quota: GLMQuota) async {
        guard let forecastMonitor else { return }
        let sessions = forecastSessions?() ?? []
        do {
            let (forecast, analytics) = try await forecastMonitor.ingestGLMQuota(
                quota, now: Date(), sessions: sessions)
            mutate {
                $0.glmForecast = forecast
                $0.forecastAnalytics = analytics
            }
        } catch {
            UsageLog.note("forecast", [("err", "ingest failed")])
        }
    }

    /// Ручной/тестовый прогон независимого analytics-цикла. Сбой чтения
    /// не бросается наружу: последний хороший снимок остаётся в снапшоте.
    public func refreshAnalytics() async {
        guard let forecastMonitor else { return }
        let sessions = forecastSessions?() ?? []
        do {
            let analytics = try await forecastMonitor.poll(now: Date(), sessions: sessions)
            mutate { $0.forecastAnalytics = analytics }
        } catch {
            UsageLog.note("analytics", [("err", "poll failed")])
        }
    }

    /// Чистая резолюция имён (публичная для тестов). id агентов не трогает —
    /// identity ставит движок и переживёт декорирование.
    nonisolated static func resolvedAgentNames(_ agents: [GLMAgentForecast],
                                               sessions: [(uuid: String, name: String)],
                                               offsets: [String: UInt64],
                                               cwds: [String: String]) -> [GLMAgentForecast] {
        let byUUID = Dictionary(sessions.map { ($0.uuid, $0.name) }, uniquingKeysWith: { first, _ in first })
        let slugs = Dictionary(offsets.keys.map { path -> (String, String) in
            let url = URL(fileURLWithPath: path)
            return (url.deletingPathExtension().lastPathComponent.lowercased(),
                    url.deletingLastPathComponent().lastPathComponent)
        }, uniquingKeysWith: { first, _ in first })
        return agents.map { a in
            var a = a
            if let name = byUUID[a.name] {
                a.name = name
            } else {
                a.external = true
                let slug = slugs[a.name] ?? a.name
                if let cwd = cwds[slug] {
                    a.name = tildeHome(cwd)
                } else {
                    a.name = "ext:\(slug)"
                }
            }
            return a
        }
    }

    /// "/Users/me/path" → "~/path" — тот же показ, что и в таблице агентов.
    nonisolated private static func tildeHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    nonisolated static func tildeHomePath(_ path: String) -> String { tildeHome(path) }

    private func startCodexIfNeeded() {
        guard codexServer == nil, let path = resolveCodex() else { return }
        let server = CodexAppServer()
        let generation = generations[.codex, default: 0]
        server.onState = { [weak self, weak server] state in
            guard let self, let server, self.codexServer === server,
                  self.generations[.codex, default: 0] == generation else { return }
            self.setCodexState(state)
        }
        server.onRateLimits = { [weak self, weak server] update in
            guard let self, let server, self.codexServer === server,
                  self.generations[.codex, default: 0] == generation else { return }
            self.ingestRateLimits(update)
        }
        codexServer = server
        server.start(codexPath: path)
    }

    private func stopCodex() {
        let server = codexServer
        codexServer = nil
        server?.onState = nil
        server?.onRateLimits = nil
        server?.stop()
    }

    private func mutate(_ change: (inout UsageSnapshot) -> Void) {
        let before = snapshot
        change(&snapshot)
        // A poll that lands the same data is a no-op: no revision bump, no
        // disk rewrite, no broadcast. Without this, every provider's 60s
        // tick would atomically rewrite usage.json forever.
        guard snapshot != before else { return }
        snapshot.revision &+= 1
        do { try persist(snapshot) }
        catch { UsageLog.note("persistence", [("err", "\(error)")]) }
        onChange?(snapshot)
    }

    private func persist(_ value: UsageSnapshot) throws {
        guard let path else { return }
        if let persistenceError { throw persistenceError }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// Копия прогноза окна с заменённым вердиктом — дебаунс подменяет сырой
/// вердикт подтверждённым, не трогая числа.
extension GLMWindowForecast {
    func replacingVerdict(_ verdict: GLMForecastVerdict) -> GLMWindowForecast {
        GLMWindowForecast(verdict: verdict, projected: projected, remaining: remaining,
                          total: total, resetAt: resetAt, exhaustionAt: exhaustionAt,
                          headroomPercent: headroomPercent,
                          rateCreditsPerHour: rateCreditsPerHour, agentMinutes: agentMinutes)
    }
}
