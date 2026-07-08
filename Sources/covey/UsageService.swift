import Foundation

/// A fetch failure carrying a short code ("no auth"/"net"/"401"/…). A dedicated
/// type because `Result`'s failure must be an `Error` (a bare `String` is not).
struct UsageFailure: Error, Equatable { let code: String }

enum UsageService {
    /// One poll cycle: usage and plan fetched independently (partial success ok).
    static func fetchAccount() async -> Account {
        var acc = Account()
        switch await oauthGet("/api/oauth/usage") {
        case .success(let body):
            if let usage = parseUsage(body) {
                acc.usage = usage
            } else {
                acc.usageError = "parse"
            }
        case .failure(let f):
            acc.usageError = f.code
        }
        if case .success(let body) = await oauthGet("/api/oauth/profile") {
            acc.plan = parsePlan(body)
        }
        return acc
    }

    /// GET an OAuth endpoint with the stored token and Claude Code headers.
    static func oauthGet(_ path: String) async -> Result<Data, UsageFailure> {
        guard let token = readToken(), !token.isEmpty else { return .failure(UsageFailure(code: "no auth")) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure(UsageFailure(code: "\(status)")) }
            return .success(data)
        } catch {
            return .failure(UsageFailure(code: "net"))
        }
    }
}
