import Foundation

/// How a provider authenticates to its Anthropic-compatible endpoint. `oauth`
/// is claude.ai's own login (no secret injected by Covey); the other two are
/// the env vars Claude Code reads for a third-party token — see
/// <https://code.claude.com/docs/en/llm-gateway-connect>.
public enum ProviderAuth: String, Codable, CaseIterable {
    case oauth    // claude.ai login — no secret injected
    case bearer   // ANTHROPIC_AUTH_TOKEN  → Authorization: Bearer
    case apiKey   // ANTHROPIC_API_KEY     → x-api-key
}

/// Mapping of Claude Code's internal model slots to provider model names.
/// nil slots are left to claude's default.
public struct ProviderModelSlots: Codable, Equatable {
    public var haiku: String?
    public var sonnet: String?
    public var opus: String?
    public init(haiku: String? = nil, sonnet: String? = nil, opus: String? = nil) {
        self.haiku = haiku; self.sonnet = sonnet; self.opus = opus
    }
}

/// A Claude Code API provider. Pure data so new providers (Kimi, …) ship as a
/// `~/.covey/config.json` entry or a new built-in — no switching code changes.
public struct ProviderProfile: Codable, Equatable, Identifiable {
    public var id: String                         // "anthropic" | "glm" | "kimi" …
    public var label: String                      // UI label
    public var baseURL: String?                   // nil → no ANTHROPIC_BASE_URL override
    public var auth: ProviderAuth
    /// Keychain account name Covey stores the key under; nil for `.oauth`.
    public var keychainAccount: String?
    public var modelSlots: ProviderModelSlots?
    public var extraEnv: [String: String]

    public init(id: String, label: String, baseURL: String? = nil, auth: ProviderAuth = .oauth,
                keychainAccount: String? = nil, modelSlots: ProviderModelSlots? = nil,
                extraEnv: [String: String] = [:]) {
        self.id = id; self.label = label; self.baseURL = baseURL; self.auth = auth
        self.keychainAccount = keychainAccount; self.modelSlots = modelSlots
        self.extraEnv = extraEnv
    }

    /// `true` when the profile needs an API key the user must set.
    public var needsKey: Bool { auth != .oauth }

    /// The env block this profile injects at spawn, with `secret` already
    /// resolved by the caller (the GUI reads the Keychain). `.oauth` injects
    /// nothing — claude uses its own saved login.
    public func envTemplate(secret: String?) -> [String: String] {
        var env: [String: String] = [:]
        if let baseURL { env["ANTHROPIC_BASE_URL"] = baseURL }
        switch auth {
        case .oauth: break
        case .bearer: if let secret { env["ANTHROPIC_AUTH_TOKEN"] = secret }
        case .apiKey: if let secret { env["ANTHROPIC_API_KEY"] = secret }
        }
        if let s = modelSlots {
            if let v = s.haiku  { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]  = v }
            if let v = s.sonnet { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = v }
            if let v = s.opus   { env["ANTHROPIC_DEFAULT_OPUS_MODEL"]   = v }
        }
        for (k, v) in extraEnv { env[k] = v }
        return env
    }

    /// Anthropic via the claude.ai login already on the machine. Covey injects
    /// nothing; claude reads its own credentials.
    public static let anthropic = ProviderProfile(id: "anthropic", label: "Anthropic")

    /// z.ai GLM Coding Plan — the env block z.ai's own helper writes, verbatim.
    public static let glm = ProviderProfile(
        id: "glm", label: "GLM", baseURL: "https://api.z.ai/api/anthropic", auth: .bearer,
        keychainAccount: "covey.provider.glm",
        modelSlots: .init(haiku: "glm-4.7", sonnet: "glm-5.2[1m]", opus: "glm-5.2[1m]"),
        extraEnv: ["API_TIMEOUT_MS": "3000000",
                   "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
}

/// Loads the provider list: built-ins (`anthropic`, `glm`) overlaid by user
/// entries from `~/.covey/config.json`. `anthropic` is always first; a
/// `defaultProvider` is hoisted to second. Adding a provider = one config entry.
public enum ProviderRegistry {
    public static func load(path: String = CoveyConfig.defaultPath) -> [ProviderProfile] {
        var byId: [String: ProviderProfile] = [
            ProviderProfile.anthropic.id: ProviderProfile.anthropic,
            ProviderProfile.glm.id: ProviderProfile.glm,
        ]
        let cfg = CoveyConfig.load(path: path)
        for p in cfg.providers ?? [] where !p.id.isEmpty {
            byId[p.id] = p   // user entry overrides a built-in of the same id
        }
        var rest = byId.filter { $0.key != ProviderProfile.anthropic.id }
        let ordered: [ProviderProfile]
        if let dp = cfg.defaultProvider, let hoisted = rest.removeValue(forKey: dp) {
            ordered = [hoisted] + rest.values.sorted { $0.id < $1.id }
        } else {
            ordered = rest.values.sorted { $0.id < $1.id }
        }
        return [ProviderProfile.anthropic] + ordered
    }

    public static func profile(id: String, path: String = CoveyConfig.defaultPath) -> ProviderProfile? {
        load(path: path).first { $0.id == id }
    }
}
