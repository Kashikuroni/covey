import CoveyKit

/// Pure rules shared by the new-session form and provider credentials UI.
enum SessionProviderSelection {
    static let defaultClaudeProviderId = ProviderProfile.anthropic.id

    static func providerChoiceIsVisible(agent: String) -> Bool {
        agent == "claude"
    }

    static func effectiveProviderId(agent: String, selectedId: String) -> String? {
        providerChoiceIsVisible(agent: agent) ? selectedId : nil
    }

    static func credentialProfiles(_ profiles: [ProviderProfile]) -> [ProviderProfile] {
        profiles.filter(\.needsKey)
    }
}
