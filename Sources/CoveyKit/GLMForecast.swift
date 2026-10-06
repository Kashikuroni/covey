import Foundation

/// Вердикт прогноза для одного квота-окна GLM. `idle` — активных агентов нет
/// или темп ≈ 0 (прогнозировать нечего); `calibrating` — темп есть, но
/// спроецировать в кредиты пока не во что (нет ни свежего фактора, ни дельт).
public enum GLMForecastVerdict: String, Codable, Equatable, Sendable {
    case fits, tight, overflow, underuse, idle, calibrating
}

/// Токены одного среза, разложенные по типам биллинга GLM.
public struct GLMTokenUsage: Codable, Equatable, Sendable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheCreation: Double = 0
    public var cacheRead: Double = 0
    public init(input: Double = 0, output: Double = 0, cacheCreation: Double = 0, cacheRead: Double = 0) {
        self.input = input; self.output = output; self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
    }
    public var total: Double { input + output + cacheCreation + cacheRead }
    /// Доля попаданий в кэш (этап 1): cacheRead / (cacheRead + input +
    /// cacheCreation). nil — данных нет. Высокий hit = контекст оплачивается
    /// кэш-ценой, а не полной ценой input.
    public var cacheHit: Double? {
        let denom = cacheRead + input + cacheCreation
        return denom > 0 ? cacheRead / denom : nil
    }
}

public struct GLMWindowForecast: Codable, Equatable, Sendable {
    public init(verdict: GLMForecastVerdict, projected: Double, remaining: Double, total: Double,
                resetAt: Int64?, exhaustionAt: Int64?, headroomPercent: Double,
                rateCreditsPerHour: Double, agentMinutes: Double?,
                projectedP50: Double? = nil, projectedP90: Double? = nil) {
        self.verdict = verdict; self.projected = projected; self.remaining = remaining
        self.total = total; self.resetAt = resetAt; self.exhaustionAt = exhaustionAt
        self.headroomPercent = headroomPercent
        self.rateCreditsPerHour = rateCreditsPerHour; self.agentMinutes = agentMinutes
        self.projectedP50 = projectedP50; self.projectedP90 = projectedP90
    }
    public var verdict: GLMForecastVerdict
    public var projected: Double          // кредиты к resetAt при текущем темпе
    public var remaining: Double          // кредиты сейчас
    public var total: Double
    public var resetAt: Int64?            // Unix ms сброса окна (из GLMLimitWindow)
    public var exhaustionAt: Int64?       // Unix ms, когда remaining кончится
    public var headroomPercent: Double    // 100 − projected/total·100 (минус = перебор)
    public var rateCreditsPerHour: Double // бленд-темп, на котором построен прогноз
    public var agentMinutes: Double?      // общий запас в агент-минутах
    public var projectedP50: Double? = nil // полоса p50 недельной проекции (§7d)
    public var projectedP90: Double? = nil // полоса p90 недельной проекции (§7d)
}

public struct GLMAgentForecast: Codable, Equatable, Sendable {
    public init(name: String, id: String? = nil, external: Bool, active: Bool, isSidechainMarked: Bool,
                tokensPerHour: Double, creditsPerHour: Double, sharePercent: Double,
                budgetMinutes: Double?, cacheHit: Double? = nil, sidechainShare: Double? = nil,
                contextTokens: Double? = nil, contextDeltaPerTurn: Double? = nil) {
        self.name = name; self.id = id; self.external = external; self.active = active
        self.isSidechainMarked = isSidechainMarked; self.tokensPerHour = tokensPerHour
        self.creditsPerHour = creditsPerHour; self.sharePercent = sharePercent
        self.budgetMinutes = budgetMinutes
        self.cacheHit = cacheHit; self.sidechainShare = sidechainShare
        self.contextTokens = contextTokens; self.contextDeltaPerTurn = contextDeltaPerTurn
    }
    public var name: String
    public var id: String?                // ключ сессии: identity строки, переживает декорирование
    public var external: Bool             // запущен вне Covey
    public var active: Bool               // транскрипт моложе 10 мин
    public var isSidechainMarked: Bool    // расход в основном субагентами
    public var tokensPerHour: Double
    public var creditsPerHour: Double
    public var sharePercent: Double
    public var budgetMinutes: Double?     // при своём темпе до конца окна
    public var cacheHit: Double?          // hit за последние 15 мин (этап 1)
    public var sidechainShare: Double?    // фактическая доля субагентов 0…1 (этап 1)
    public var contextTokens: Double?     // размер промпта последнего хода (этап 2)
    public var contextDeltaPerTurn: Double? // рост контекста за ход (этап 2)
    /// Стабильный id для UI-списков: у нескольких агентов имя (проект) может
    /// совпасть — дубликаты в ForEach схлопывают строки.
    public var stableID: String { id ?? "name:\(name)" }
}

public struct GLMModelUsage: Codable, Equatable, Sendable {
    public init(model: String, window: GLMTokenUsage, lastHour: GLMTokenUsage) {
        self.model = model; self.window = window; self.lastHour = lastHour
    }
    public var model: String
    public var window: GLMTokenUsage      // с начала квота-окна
    public var lastHour: GLMTokenUsage
}

/// Токены одного локального дня по моделям — столбчатый график 7d (§7d).
public struct GLMDayUsage: Codable, Equatable, Sendable {
    public init(t: Int64, models: [String: Double], usage: [String: GLMTokenUsage]? = nil) {
        self.t = t; self.models = models; self.usage = usage
    }
    public var t: Int64                   // Unix ms полуночи локального дня
    public var models: [String: Double]   // модель → total-токены за день
    public var usage: [String: GLMTokenUsage]? // компоненты биллинга (для $)
}

/// Токены одного часа по моделям с компонентами биллинга — $-линия дня
/// (§spend). История 8 дней (живые вёдра), upsert по часу.
public struct GLMHourUsage: Codable, Equatable, Sendable {
    public init(t: Int64, usage: [String: GLMTokenUsage]) {
        self.t = t; self.usage = usage
    }
    public var t: Int64                     // Unix ms начала часа
    public var usage: [String: GLMTokenUsage]
}

/// Пожизненный тотал сессии для журнала стоимости (этап 0 roadmap: копится
/// в сторе, UI — этап 2). Тоталы монотонны: вёдра прунятся, снапшот меньше
/// накопленного тотала его не откатывает.
public struct SessionCostRecord: Codable, Equatable, Sendable {
    public init(firstSeen: Int64, lastSeen: Int64, byModel: [String: Double],
                external: Bool, cwd: String?,
                usage: [String: GLMTokenUsage]? = nil) {
        self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.byModel = byModel; self.external = external; self.cwd = cwd
        self.usage = usage
    }
    public var firstSeen: Int64           // Unix ms первого замеченного вёдра
    public var lastSeen: Int64            // Unix ms последней активности
    public var byModel: [String: Double]  // total-токены по моделям (совместимость)
    public var external: Bool             // запущена вне Covey
    public var cwd: String?               // путь проекта на момент активности
    public var usage: [String: GLMTokenUsage]? // компоненты биллинга (для $)
}

/// Текущий контекст сессии: размер промпта последнего хода и его рост
/// (последний − предпоследний ход; отрицательный = контекст сброшен).
public struct LastContextRecord: Codable, Equatable, Sendable {
    public init(tokens: Double, t: Int64, deltaPerTurn: Double?) {
        self.tokens = tokens; self.t = t; self.deltaPerTurn = deltaPerTurn
    }
    public var tokens: Double             // input + cacheCreation + cacheRead последнего хода
    public var t: Int64                   // Unix ms этого хода
    public var deltaPerTurn: Double?
}

public struct GLMSeriesPoint: Codable, Equatable, Sendable {
    public init(t: Int64, used: Double) { self.t = t; self.used = used }
    public var t: Int64                   // Unix ms
    public var used: Double               // кредиты, накопительно в окне
}

public struct GLMForecast: Codable, Equatable, Sendable {
    public init() {}
    public var fiveHours: GLMWindowForecast?
    public var weekly: GLMWindowForecast?
    public var tokensPerHour: Double = 0  // аккаунтный мгновенный токен-темп
    public var factorPeak: Double?        // кредиты/токен, откалиброванные в пике
    public var factorOffPeak: Double?
    public var factorPeakAt: Int64?       // Unix ms последней калибровки фактора
    public var factorOffPeakAt: Int64?
    public var peakNow: Bool = false
    public var nextFlipAt: Int64?         // Unix ms ближайшей смены режима
    // Compatibility-only analytics fields. New snapshots publish the same
    // information through UsageSnapshot.forecastAnalytics.
    public var agents: [GLMAgentForecast] = []
    public var models: [GLMModelUsage] = []
    public var modelDaily: [GLMDayUsage]? // дневные токены по моделям (столбцы 7d)
    public var fiveHourSeries: [GLMSeriesPoint] = []
    public var weeklySeries: [GLMSeriesPoint] = []
    public var coverage7d: Double?        // доля времени мониторинга без разрывов (этап 1)
    public var sessionCosts: [GLMSessionCostEntry]? // журнал стоимости сессий (этап 2)
    public var hourly: [GLMSeriesPoint]?  // токены по часам, 90 дней (этап 2)
    public var modelHourly: [GLMHourUsage]? // час × модель × компоненты (§spend, 8 дней)
}

/// Запись журнала стоимости для UI (этап 2): стор-рекорд + резолвнутое имя
/// и признак живой сессии.
public struct GLMSessionCostEntry: Codable, Equatable, Sendable {
    public init(record: SessionCostRecord, name: String, live: Bool) {
        self.record = record; self.name = name; self.live = live
    }
    public var record: SessionCostRecord
    public var name: String              // имя Covey-сессии или ~/<проект>
    public var live: Bool                // активна в ledger (false — архив)
}
