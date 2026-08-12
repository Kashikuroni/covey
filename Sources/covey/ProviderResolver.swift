import CoveyKit

enum ProviderResolverError: Error, Equatable { case missingKey(String) }

/// Resolves a provider profile to a spawn-time env dict. The secret is read via
/// `readSecret` (the GUI wires it to `ProviderKeychain.read`) so the resolver
/// itself stays Keychain-free and unit-testable with an injected reader.
enum ProviderResolver {
    static func resolve(profile: ProviderProfile,
                        readSecret: (String) throws -> String?) throws -> [String: String] {
        guard profile.needsKey else { return profile.envTemplate(secret: nil) }
        guard let account = profile.keychainAccount else {
            throw ProviderResolverError.missingKey(profile.id)
        }
        let secret = try readSecret(account)
        guard let secret, !secret.isEmpty else {
            throw ProviderResolverError.missingKey(profile.id)
        }
        return profile.envTemplate(secret: secret)
    }
}
