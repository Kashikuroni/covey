import CoveyKit

/// Pure rules shared by the provider credentials UI.
enum SessionProviderSelection {
    static func credentialProfiles(_ profiles: [ProviderProfile]) -> [ProviderProfile] {
        profiles.filter(\.needsKey)
    }
}
