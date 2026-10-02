import CoveyKit
import Foundation

/// Fetches the z.ai quota endpoint. Mirrors `UsageService` (Claude): one
/// short-code error surface, `UsageLog` breadcrumbs, and thin URLSession use
/// the monitor stays testable around.
public enum GlmUsageService {
    /// Keychain item shared with the retired GLM provider profile, so a key
    /// stored before the retirement keeps working.
    public static let keychainAccount = glmKeychainAccount

    /// One poll cycle. The key is read per fetch — the limits window can add
    /// or edit it at any moment.
    public static func fetchGLMAccount() async -> GLMAccount {
        guard let key = ProviderKeychain.read(account: keychainAccount), !key.isEmpty else {
            UsageLog.note("glm", [("path", "/api/monitor/usage/quota/limit"), ("err", "no auth")])
            return GLMAccount(error: "no auth")
        }
        return await fetchGLMAccount(key: key)
    }

    /// Fetch with an explicit key; an empty key short-circuits to "no auth"
    /// without touching the network.
    public static func fetchGLMAccount(key: String) async -> GLMAccount {
        guard !key.isEmpty else { return GLMAccount(error: "no auth") }
        guard let req = quotaRequest(key: key) else { return GLMAccount(error: "net") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                UsageLog.note("glm", [("path", req.url?.path ?? ""), ("status", status),
                                      ("body", UsageLog.excerpt(data))])
                return GLMAccount(error: "\(status)")
            }
            guard let quota = parseGLMQuota(data) else {
                UsageLog.note("glm", [("path", req.url?.path ?? ""), ("err", "parse"),
                                      ("body", UsageLog.excerpt(data))])
                return GLMAccount(error: "parse")
            }
            return GLMAccount(quota: quota)
        } catch {
            UsageLog.note("glm", [("path", req.url?.path ?? ""), ("err", "net"),
                                  ("detail", "\(error)")])
            return GLMAccount(error: "net")
        }
    }

    /// The monitor request: z.ai takes the key verbatim in `Authorization` —
    /// no Bearer scheme, exactly like the dashboard's own calls.
    static func quotaRequest(key: String) -> URLRequest? {
        guard let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(key, forHTTPHeaderField: "Authorization")
        return req
    }
}
