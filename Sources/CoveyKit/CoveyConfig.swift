import Foundation

/// Опциональная секция `glmForecast` в config.json: настройки прогноза квоты
/// GLM. Все поля опциональны — дефолты (true / 15 / 20) применяет потребитель,
/// не декодер: отсутствие ключа и явный `null` неразличимы.
public struct GLMForecastConfigSection: Codable, Equatable {
    public var includeExternal: Bool?
    public var marginPercent: Double?
    public var imminentMinutes: Double?
    /// Спайк-алерты (этап 3): во сколько раз темп сессии должен превысить
    /// недельную ставку; nil → 8, 0 — выключить.
    public var spikeMultiplier: Double?
    public init(includeExternal: Bool? = nil, marginPercent: Double? = nil,
                imminentMinutes: Double? = nil, spikeMultiplier: Double? = nil) {
        self.includeExternal = includeExternal; self.marginPercent = marginPercent
        self.imminentMinutes = imminentMinutes
        self.spikeMultiplier = spikeMultiplier
    }
}

/// User-editable app config (`~/.covey/config.json`), read-only at runtime.
public struct CoveyConfig: Codable, Equatable {
    public var defaultAgent: String?
    public var agentPresets: [String]?
    /// User-defined / overridden Claude Code provider profiles, merged over the
    /// built-ins (`anthropic`) by id. See `ProviderRegistry`.
    public var providers: [ProviderProfile]?
    /// Provider id hoisted to the top of the picker (anthropic is always first
    /// regardless; this controls the second slot).
    public var defaultProvider: String?
    /// Forecast settings for the GLM quota windows; nil (absent) = defaults.
    public var glmForecast: GLMForecastConfigSection?

    public init(defaultAgent: String? = nil, agentPresets: [String]? = nil,
                providers: [ProviderProfile]? = nil, defaultProvider: String? = nil,
                glmForecast: GLMForecastConfigSection? = nil) {
        self.defaultAgent = defaultAgent
        self.agentPresets = agentPresets
        self.providers = providers
        self.defaultProvider = defaultProvider
        self.glmForecast = glmForecast
    }

    public static func load(path: String = defaultPath) -> CoveyConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(CoveyConfig.self, from: data)
        else { return CoveyConfig() }
        return cfg
    }

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/config.json").path
    }

    /// Presets for the agent picker: the config's list (default agent first)
    /// or the built-in fallback.
    public var presets: [String] {
        var list = agentPresets ?? ["claude", "codex"]
        if let defaultAgent {
            list.removeAll { $0 == defaultAgent }
            list.insert(defaultAgent, at: 0)
        }
        return list
    }
}
