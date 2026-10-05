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
}

public struct GLMWindowForecast: Codable, Equatable, Sendable {
    public init(verdict: GLMForecastVerdict, projected: Double, remaining: Double, total: Double,
                resetAt: Int64?, exhaustionAt: Int64?, headroomPercent: Double,
                rateCreditsPerHour: Double, agentMinutes: Double?) {
        self.verdict = verdict; self.projected = projected; self.remaining = remaining
        self.total = total; self.resetAt = resetAt; self.exhaustionAt = exhaustionAt
        self.headroomPercent = headroomPercent
        self.rateCreditsPerHour = rateCreditsPerHour; self.agentMinutes = agentMinutes
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
}

public struct GLMAgentForecast: Codable, Equatable, Sendable {
    public init(name: String, external: Bool, active: Bool, isSidechainMarked: Bool,
                tokensPerHour: Double, creditsPerHour: Double, sharePercent: Double,
                budgetMinutes: Double?) {
        self.name = name; self.external = external; self.active = active
        self.isSidechainMarked = isSidechainMarked; self.tokensPerHour = tokensPerHour
        self.creditsPerHour = creditsPerHour; self.sharePercent = sharePercent
        self.budgetMinutes = budgetMinutes
    }
    public var name: String
    public var external: Bool             // запущен вне Covey
    public var active: Bool               // транскрипт моложе 10 мин
    public var isSidechainMarked: Bool    // расход в основном субагентами
    public var tokensPerHour: Double
    public var creditsPerHour: Double
    public var sharePercent: Double
    public var budgetMinutes: Double?     // при своём темпе до конца окна
}

public struct GLMModelUsage: Codable, Equatable, Sendable {
    public init(model: String, window: GLMTokenUsage, lastHour: GLMTokenUsage) {
        self.model = model; self.window = window; self.lastHour = lastHour
    }
    public var model: String
    public var window: GLMTokenUsage      // с начала квота-окна
    public var lastHour: GLMTokenUsage
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
    public var agents: [GLMAgentForecast] = []
    public var models: [GLMModelUsage] = []
    public var fiveHourSeries: [GLMSeriesPoint] = []
    public var weeklySeries: [GLMSeriesPoint] = []
}
