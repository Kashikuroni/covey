import Foundation

/// User-editable app config (`~/.covey/config.json`), read-only at runtime.
public struct CoveyConfig: Codable, Equatable {
    public var defaultAgent: String?
    public var agentPresets: [String]?
    /// User-defined / overridden Claude Code provider profiles, merged over the
    /// built-ins (`anthropic`, `glm`) by id. See `ProviderRegistry`.
    public var providers: [ProviderProfile]?
    /// Provider id hoisted to the top of the picker (anthropic is always first
    /// regardless; this controls the second slot).
    public var defaultProvider: String?

    public init(defaultAgent: String? = nil, agentPresets: [String]? = nil,
                providers: [ProviderProfile]? = nil, defaultProvider: String? = nil) {
        self.defaultAgent = defaultAgent
        self.agentPresets = agentPresets
        self.providers = providers
        self.defaultProvider = defaultProvider
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
