import CoveyKit

func providerKeyLabel(profile: ProviderProfile, status: ProviderKeyStatus) -> String {
    switch status {
    case .checking: return "Checking…"
    case .set: return "\(profile.label) API key set ✓"
    case .missing: return "Set \(profile.label) API key…"
    }
}
func providerKeyMutationError(_ result: ProviderKeyMutationResult) -> String? {
    switch result {
    case .success: return nil
    case .failure(let message): return message
    }
}
