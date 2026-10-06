import Foundation
import CoveyKit

/// Провайдер-нейтральная аналитика: модели/дни/часы/сессии/стоимости из
/// общего агрегатора и стора. GLM-кредиты и бюджеты навешиваются только на
/// реально GLM-сессии из `glmForecast.agents`; GPT-токены не участвуют в
/// GLM rate/калибровке — движок читает только `glmSessionRates`.
/// Имена: Codex — из sessionMetadata и матчинга реестра (cwd), Claude — из
/// source ID реестра, внешние — tilde-домашний cwd.
public enum ForecastAnalyticsBuilder {
    public static func build(aggregator: TokenAggregator, store: QuotaSampleStore,
                             identities: [ForecastSessionIdentity],
                             glmForecast: GLMForecast?, now: Date) -> ForecastAnalytics {
        var out = ForecastAnalytics()
        out.models = aggregator.perModel(windowStart: now.addingTimeInterval(-5 * 3600),
                                         hourStart: now.addingTimeInterval(-3600))
        out.modelDaily = store.modelDays
        out.hourly = store.hourTotals
        out.modelHourly = store.hourUsage

        let metadata = store.sessionMetadata
        let bySourceID = Dictionary(
            identities.compactMap { identity in
                identity.sourceID.map { ($0, identity.name) }
            }, uniquingKeysWith: { first, _ in first })
        var byCodexCwd: [String: String] = [:]
        for identity in identities where CodexTranscript.isCodexAgent(identity.agent) {
            let key = URL(fileURLWithPath: identity.cwd).standardizedFileURL.path
            if byCodexCwd[key] == nil { byCodexCwd[key] = identity.name }
        }
        let glmAgents = Dictionary(
            (glmForecast?.agents ?? []).compactMap { agent in agent.id.map { ($0, agent) } },
            uniquingKeysWith: { first, _ in first })
        let cwds = store.cwds

        func codexName(key: String, cwd: String?) -> String {
            if let cwd,
               metadata[key]?.external != true,
               let matched = byCodexCwd[URL(fileURLWithPath: cwd).standardizedFileURL.path] {
                return matched
            }
            if let cwd { return UsageMonitor.tildeHomePath(cwd) }
            return key
        }

        out.sessions = aggregator.allSessionRates(now: now, idle: 600).map { rate in
            let isCodex = rate.key.hasPrefix("codex:")
            let name: String
            let external: Bool
            if isCodex {
                let meta = metadata[rate.key]
                external = meta?.external ?? true
                name = codexName(key: rate.key, cwd: meta?.cwd)
            } else if let registered = bySourceID[rate.key] {
                name = registered
                external = false
            } else {
                // Внешний claude-транскрипт: slug ключа → известный cwd.
                external = true
                if let cwd = cwds[rate.key] {
                    name = UsageMonitor.tildeHomePath(cwd)
                } else {
                    name = "ext:\(rate.key)"
                }
            }
            let ctx = store.lastContext[rate.key]
            let agent = glmAgents[rate.key]
            return ForecastSessionUsage(
                id: rate.key, name: name,
                source: isCodex ? .codex : .claudeCode,
                external: external, active: rate.active,
                tokensPerHour: rate.tokensPerHour,
                cacheHit: rate.cacheHit,
                contextTokens: ctx?.tokens,
                contextDeltaPerTurn: ctx?.deltaPerTurn,
                creditsPerHour: agent?.creditsPerHour,
                budgetMinutes: agent?.budgetMinutes)
        }

        func costEntry(key: String, record: SessionCostRecord, live: Bool)
            -> ForecastSessionCostEntry {
            let isCodex = key.hasPrefix("codex:")
            let name: String
            if isCodex {
                name = codexName(key: key, cwd: record.cwd ?? metadata[key]?.cwd)
            } else if let registered = bySourceID[key] {
                name = registered
            } else {
                name = record.cwd.map(UsageMonitor.tildeHomePath) ?? key
            }
            return ForecastSessionCostEntry(record: record, name: name,
                                            source: isCodex ? .codex : .claudeCode,
                                            live: live)
        }
        out.sessionCosts = (store.sessionLedger.map { costEntry(key: $0.key, record: $0.value, live: true) }
            + store.sessionArchive.map { costEntry(key: $0.key, record: $0.value, live: false) })
            .sorted {
                $0.record.lastSeen == $1.record.lastSeen
                    ? $0.name < $1.name : $0.record.lastSeen > $1.record.lastSeen
            }
        return out
    }
}
