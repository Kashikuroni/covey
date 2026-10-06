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
    // Прогноз GLM (все nil → прогноз выключен, монитор ведёт себя как раньше).
    public private(set) var forecastStore: QuotaSampleStore?
    private var transcriptWatcher: TranscriptWatcher?
    private var glmSessions: (() -> [(uuid: String, name: String, isGLM: Bool)])?
    private var aggregator: TokenAggregator
    private var config: GLMForecastConfig
    private var factors = CalibrationFactors()
    private var lastRawVerdicts: [String: GLMForecastVerdict] = [:]   // "five"|"week" → сырой
    private var confirmedVerdicts: [String: GLMForecastVerdict] = [:]

    public init(path: String? = nil, legacyPath: String? = nil,
                fetchAccount: @escaping () async -> Account = UsageService.fetchAccount,
                fetchGLM: @escaping () async -> GLMAccount = GlmUsageService.fetchGLMAccount,
                usageInterval: TimeInterval = 60,
                resolveCodex: @escaping () -> String? = resolveCodexPath,
                forecastStore: QuotaSampleStore? = nil,
                transcriptWatcher: TranscriptWatcher? = nil,
                forecastAggregator: TokenAggregator? = nil,
                glmSessions: (() -> [(uuid: String, name: String, isGLM: Bool)])? = nil) {
        self.path = path
        self.fetchAccount = fetchAccount
        self.fetchGLM = fetchGLM
        self.usageInterval = max(0.01, usageInterval)
        self.resolveCodex = resolveCodex
        self.forecastStore = forecastStore
        // Спека §4.1: рестарт демона не сбрасывает калибровку — сеем факторы
        // из стора, иначе первый updateForecast перезаписал бы persisted
        // пустым дефолтом.
        if let forecastStore { factors = CalibrationFactors(forecastStore.factors) }
        self.transcriptWatcher = transcriptWatcher
        self.glmSessions = glmSessions
        // Тот же экземпляр, что у вотчера, иначе вёдра не доедут до прогноза.
        self.aggregator = forecastAggregator ?? TokenAggregator(buckets: forecastStore?.buckets ?? [])
        let cfg = CoveyConfig.load()
        self.config = GLMForecastConfig(
            includeExternal: cfg.glmForecast?.includeExternal ?? true,
            marginPercent: cfg.glmForecast?.marginPercent ?? 15,
            imminentMinutes: cfg.glmForecast?.imminentMinutes ?? 20)
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
            if let quota = account.quota { updateForecast(quota: quota) }
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

    /// Прогноз-цикл успешного GLM-поллинга: дочитать транскрипты, приложить
    /// сэмпл квоты, собрать и украсить прогноз, опубликовать и сохранить стор.
    private func updateForecast(quota: GLMQuota) {
        guard let store = forecastStore else { return }
        let now = Date()
        transcriptWatcher?.poll(now: now)
        // Сэмпл из текущего quota (5h и weekly used/reset).
        func entry(_ w: GLMLimitWindow?) -> (used: Double, reset: Int64) {
            (w?.used ?? 0, w?.resetAt ?? 0)
        }
        let five = entry(quota.limits.fiveHours), week = entry(quota.limits.weekly)
        let sample = QuotaSample(t: Int64(now.timeIntervalSince1970 * 1000),
                                 fiveUsed: five.used, fiveReset: five.reset,
                                 weekUsed: week.used, weekReset: week.reset)
        store.append(sample)
        store.setBuckets(aggregator.buckets)   // вёдра вотчера едут в стор на диск
        // Дневные токены по моделям: вёдра живут 8 дней, год истории — в сторе.
        store.upsertModelDays(aggregator.perDay(now: now, days: 8), now: now)
        // Этап 0 (roadmap): журнал стоимости сессий и почасовые роллапы.
        store.upsertSessions(sessionCostRecords(), now: now)
        store.upsertHourTotals(aggregator.hourTotals(now: now), now: now)
        store.upsertHourUsage(aggregator.perHour(now: now, days: 8), now: now)
        let (forecast, newFactors) = ForecastEngine.build(
            fiveHours: quota.limits.fiveHours, weekly: quota.limits.weekly,
            aggregator: aggregator, store: store, factors: factors, now: now,
            config: config)
        factors = newFactors
        store.setFactors(factors.persisted)
        var decorated = forecast
        decorated.agents = resolveAgentNames(forecast.agents)
        decorated.fiveHours = debounced("five", forecast.fiveHours)
        decorated.weekly = debounced("week", forecast.weekly)
        // Этап 2: журнал стоимости сессий и почасовки теплокарты — в снапшот.
        decorated.sessionCosts = sessionCostEntries()
        decorated.hourly = store.hourTotals
        decorated.modelHourly = store.hourUsage
        // Бюджеты агентов (§4.4): остаток 5h-окна / собственный кредитный темп агента.
        if let five = decorated.fiveHours, five.remaining > 0 {
            decorated.agents = decorated.agents.map { a in
                var a = a
                a.budgetMinutes = a.creditsPerHour > 0 ? five.remaining / a.creditsPerHour * 60 : nil
                return a
            }
        }
        mutate { $0.glmForecast = decorated }
        try? store.save()
    }

    /// Записи журнала стоимости для UI (этап 2): ledger + архив, с именами
    /// (uuid → Covey-сессия; внешняя — ~/<проект>), топ-100 по тоталу.
    private func sessionCostEntries() -> [GLMSessionCostEntry] {
        guard let store = forecastStore else { return [] }
        let byUUID = Dictionary((glmSessions?() ?? []).map { ($0.uuid, $0.name) },
                                uniquingKeysWith: { first, _ in first })
        func entry(_ pair: (uuid: String, rec: SessionCostRecord), live: Bool)
            -> GLMSessionCostEntry {
            let name = byUUID[pair.uuid]
                ?? pair.rec.cwd.map(Self.tildeHomePath)
                ?? pair.uuid
            return GLMSessionCostEntry(record: pair.rec, name: name, live: live)
        }
        return (store.sessionLedger.map { entry($0, live: true) }
            + store.sessionArchive.map { entry($0, live: false) })
            .sorted {
                $0.record.byModel.values.reduce(0, +) > $1.record.byModel.values.reduce(0, +)
            }
            .prefix(100).map { $0 }
    }

    /// Снапшот пожизненных тоталов сессий для журнала (этап 0): вёдра →    /// записи; внешний/путь — тем же резолвом, что и имена агентов.
    private func sessionCostRecords() -> [String: SessionCostRecord] {
        let known = Set((glmSessions?() ?? []).map(\.uuid))
        let slugs = Dictionary((forecastStore?.offsets ?? [:]).keys.map { path -> (String, String) in
            let url = URL(fileURLWithPath: path)
            return (url.deletingPathExtension().lastPathComponent.lowercased(),
                    url.deletingLastPathComponent().lastPathComponent)
        }, uniquingKeysWith: { first, _ in first })
        let cwds = forecastStore?.cwds ?? [:]
        var out: [String: SessionCostRecord] = [:]
        for (uuid, tot) in aggregator.sessionTotals() {
            let external = !known.contains(uuid)
            out[uuid] = SessionCostRecord(
                firstSeen: tot.first, lastSeen: tot.last, byModel: tot.byModel,
                external: external,
                cwd: external ? cwds[slugs[uuid] ?? ""] : nil,
                usage: tot.usage)
        }
        return out
    }

    /// Имена агентов: uuid → имя Covey-сессии из `glmSessions`; ключ без
    /// сессии — внешний: имя — реальный cwd проекта (вотчер снимает его из
    /// транскрипта, `store.cwds`), свёрнутый к «~» — slug каталога сплющен
    /// в «-» и путь по нему не восстановить; без снятого cwd — «ext:<slug>».
    private func resolveAgentNames(_ agents: [GLMAgentForecast]) -> [GLMAgentForecast] {
        UsageMonitor.resolvedAgentNames(agents,
                                        sessions: (glmSessions?() ?? []).map { ($0.uuid, $0.name) },
                                        offsets: forecastStore?.offsets ?? [:],
                                        cwds: forecastStore?.cwds ?? [:])
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

    /// Публикуем вердикт только когда он продержался два опроса подряд;
    /// до того держим прошлый подтверждённый (в первый цикл — .calibrating).
    private func debounced(_ key: String, _ w: GLMWindowForecast?) -> GLMWindowForecast? {
        guard var w = w else { return nil }
        let raw = w.verdict
        defer { lastRawVerdicts[key] = raw }
        guard let last = lastRawVerdicts[key] else {
            return w.replacingVerdict(.calibrating)   // первый опрос: сырого не с чем сравнить
        }
        if last == raw { confirmedVerdicts[key] = raw }
        w.verdict = confirmedVerdicts[key] ?? raw
        return w
    }

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
