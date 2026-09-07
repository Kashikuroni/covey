import CoveyKit

extension ProviderProfile {
    static let testProvider = ProviderProfile(id: "custom", label: "Custom",
        baseURL: "https://provider.example/anthropic", auth: .bearer,
        keychainAccount: "covey.provider.custom")
}
