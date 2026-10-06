import Foundation
import CoveyKit

/// Единоличный владелец прогнозного стора, агрегатора и обоих transcript
/// вотчеров. Сериализует backfill, GLM-калибровку и сохранение: всё внутри
/// актора, поэтому гонок между циклами нет. Опрашивается отдельным
/// 60-секундным analytics-циклом `UsageMonitor`, независимым от сетевых
/// провайдер-поллингов; GLM-квота приезжает через `ingestGLMQuota`.
///
/// Source-level сбои чтения — throwable: вызывающий сохраняет последний
/// хороший снимок; битые строки остаются счётчиками парсеров.
public actor ForecastAnalyticsMonitor {
    private let store: QuotaSampleStore
    private let aggregator: TokenAggregator
    private let claudeWatcher: TranscriptWatcher?
    private let codexWatcher: CodexTranscriptWatcher?
    private let glmConfig: GLMForecastConfig
    private var factors: CalibrationFactors
    private var lastRawVerdicts: [String: GLMForecastVerdict] = [:]
    private var confirmedVerdicts: [String: GLMForecastVerdict] = [:]
    /// Последний украшенный GLM-прогноз: бюджеты/имена для аналитики между
    /// GLM-поллами.
    private var lastDecorated: GLMForecast?

    public init(store: QuotaSampleStore, aggregator: TokenAggregator,
                claudeWatcher: TranscriptWatcher?,
                codexWatcher: CodexTranscriptWatcher?,
                glmConfig: GLMForecastConfig) {
        self.store = store
        self.aggregator = aggregator
        self.claudeWatcher = claudeWatcher
        self.codexWatcher = codexWatcher
        self.glmConfig = glmConfig
        self.factors = CalibrationFactors(store.factors)
    }

    /// Независимый analytics-цикл: дочитать оба вотчера, обновить
    /// производную историю, собрать провайдер-нейтральную аналитику и
    /// атомарно сохранить стор.
    public func poll(now: Date, sessions: [ForecastSessionIdentity]) throws -> ForecastAnalytics {
        claudeWatcher?.poll(now: now, sessions: sessions)
        do {
            _ = try codexWatcher?.poll(now: now, sessions: sessions)
        } catch {
            // Спека «Ошибки и наблюдаемость»: ошибка Codex analytics не
            // останавливает Claude analytics — остальной конвейер и
            // сохранение продолжаются; курсор сбойного файла не двигается.
            UsageLog.note("codex-watch", [("err", "read failed")])
        }
        maintainDerivedHistory(now: now, sessions: sessions)
        let analytics = ForecastAnalyticsBuilder.build(aggregator: aggregator, store: store,
                                                       identities: sessions,
                                                       glmForecast: lastDecorated, now: now)
        try store.save()
        return analytics
    }

    /// Цикл успешного GLM-поллинга: вотчеры → сэмпл квоты → калибровка →
    /// прогноз → украшение → аналитика → одно атомарное сохранение.
    public func ingestGLMQuota(_ quota: GLMQuota, now: Date,
                               sessions: [ForecastSessionIdentity]) throws
        -> (forecast: GLMForecast, analytics: ForecastAnalytics) {
        claudeWatcher?.poll(now: now, sessions: sessions)
        func entry(_ w: GLMLimitWindow?) -> (used: Double, reset: Int64) {
            (w?.used ?? 0, w?.resetAt ?? 0)
        }
        let five = entry(quota.limits.fiveHours), week = entry(quota.limits.weekly)
        store.append(QuotaSample(t: Int64(now.timeIntervalSince1970 * 1000),
                                 fiveUsed: five.used, fiveReset: five.reset,
                                 weekUsed: week.used, weekReset: week.reset))
        maintainDerivedHistory(now: now, sessions: sessions)
        let (forecast, newFactors) = ForecastEngine.build(
            fiveHours: quota.limits.fiveHours, weekly: quota.limits.weekly,
            aggregator: aggregator, store: store, factors: factors, now: now,
            config: glmConfig)
        factors = newFactors
        store.setFactors(factors.persisted)

        var decorated = forecast
        decorated.agents = UsageMonitor.resolvedAgentNames(
            forecast.agents,
            sessions: sessions.compactMap { identity in
                identity.sourceID.map { ($0, identity.name) }
            },
            offsets: store.offsets, cwds: store.cwds)
        decorated.fiveHours = debounced("five", forecast.fiveHours)
        decorated.weekly = debounced("week", forecast.weekly)
        decorated.sessionCosts = compatSessionCosts(sessions: sessions)
        decorated.hourly = store.hourTotals
        decorated.modelHourly = store.hourUsage
        // Бюджеты агентов (§4.4): остаток 5h-окна / собственный темп.
        if let five = decorated.fiveHours, five.remaining > 0 {
            decorated.agents = decorated.agents.map { agent in
                var agent = agent
                agent.budgetMinutes = agent.creditsPerHour > 0
                    ? five.remaining / agent.creditsPerHour * 60 : nil
                return agent
            }
        }
        lastDecorated = decorated
        let analytics = ForecastAnalyticsBuilder.build(aggregator: aggregator, store: store,
                                                       identities: sessions,
                                                       glmForecast: decorated, now: now)
        try store.save()
        return (decorated, analytics)
    }

    // MARK: - производная история

    /// Вёдра вотчеров → стор; дневные/почасовые роллапы и журнал сессий.
    private func maintainDerivedHistory(now: Date, sessions: [ForecastSessionIdentity]) {
        store.setBuckets(aggregator.buckets)
        store.upsertModelDays(aggregator.perDay(now: now, days: 8), now: now)
        store.upsertSessions(sessionCostRecords(sessions: sessions), now: now)
        store.upsertHourTotals(aggregator.hourTotals(now: now), now: now)
        store.upsertHourUsage(aggregator.perHour(now: now, days: 8), now: now)
        // Контекст Codex-сессий: две последние точки курсора → lastContext
        // (интерпретация та же, что у claude-сканера).
        var codexContexts: [String: LastContextRecord] = [:]
        for cursor in store.codexCursors.values where !cursor.contexts.isEmpty {
            let points = cursor.contexts
            let newest = points[points.count - 1]
            codexContexts[cursor.sessionKey] = LastContextRecord(
                tokens: newest.tokens, t: newest.t,
                deltaPerTurn: points.count > 1
                    ? newest.tokens - points[points.count - 2].tokens : nil)
        }
        if !codexContexts.isEmpty { store.upsertLastContext(codexContexts) }
    }

    private func sessionCostRecords(sessions: [ForecastSessionIdentity]) -> [String: SessionCostRecord] {
        let known = Set(sessions.compactMap(\.sourceID))
        let slugs = Dictionary(store.offsets.keys.map { path -> (String, String) in
            let url = URL(fileURLWithPath: path)
            return (url.deletingPathExtension().lastPathComponent.lowercased(),
                    url.deletingLastPathComponent().lastPathComponent)
        }, uniquingKeysWith: { first, _ in first })
        let cwds = store.cwds
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

    /// Совместимые записи журнала для GLMForecast (до миграции UI на
    /// `forecastAnalytics`).
    private func compatSessionCosts(sessions: [ForecastSessionIdentity]) -> [GLMSessionCostEntry] {
        let byUUID = Dictionary(sessions.compactMap { identity in
            identity.sourceID.map { ($0, identity.name) }
        }, uniquingKeysWith: { first, _ in first })
        func entry(_ pair: (key: String, value: SessionCostRecord), live: Bool) -> GLMSessionCostEntry {
            let name = byUUID[pair.key]
                ?? pair.value.cwd.map(UsageMonitor.tildeHomePath)
                ?? pair.key
            return GLMSessionCostEntry(record: pair.value, name: name, live: live)
        }
        return (store.sessionLedger.map { entry($0, live: true) }
            + store.sessionArchive.map { entry($0, live: false) })
            .sorted {
                $0.record.lastSeen == $1.record.lastSeen
                    ? $0.name < $1.name : $0.record.lastSeen > $1.record.lastSeen
            }
    }

    /// Публикуем вердикт только когда он продержался два опроса подряд;
    /// до того держим прошлый подтверждённый (в первый цикл — .calibrating).
    private func debounced(_ key: String, _ w: GLMWindowForecast?) -> GLMWindowForecast? {
        guard var w = w else { return nil }
        let raw = w.verdict
        defer { lastRawVerdicts[key] = raw }
        guard let last = lastRawVerdicts[key] else {
            return w.replacingVerdict(.calibrating)
        }
        if last == raw { confirmedVerdicts[key] = raw }
        w.verdict = confirmedVerdicts[key] ?? raw
        return w
    }
}
