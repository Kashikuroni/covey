import Foundation

/// Parses the z.ai `/api/monitor/usage/quota/limit` body: an array of typed
/// limit entries. Only `TOKENS_LIMIT` (the 5-hour token cycle — the signal
/// that actually predicts an inference 429) is surfaced; `TIME_LIMIT` (a
/// monthly MCP-tool-call quota, a different axis entirely) is ignored.
/// This endpoint is unofficial (reverse-engineered from z.ai's own dashboard,
/// same category as Anthropic's own `/api/oauth/usage` Covey already polls),
/// so parsing is defensive: any unexpected shape returns nil rather than throwing.
func parseGlmQuota(_ body: Data) -> Usage? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let data = root["data"] as? [String: Any],
          let limits = data["limits"] as? [[String: Any]],
          let tokens = limits.first(where: { $0["type"] as? String == "TOKENS_LIMIT" }),
          let pct = tokens["percentage"] as? Double else { return nil }
    // nextResetTime is Unix milliseconds; UsageWindow.resetUnix is seconds.
    let resetUnix = (tokens["nextResetTime"] as? Double).map { Int64($0 / 1000) }
    return Usage(fiveHour: UsageWindow(utilization: pct, resetUnix: resetUnix),
                sevenDay: nil, sevenDaySonnet: nil)
}

enum GlmUsageService {
    /// One poll cycle: usage from the quota-limit endpoint, no separate plan
    /// call (z.ai's response carries no plan/tier name). nil account.usage
    /// when no GLM API key is stored — nothing to poll with yet.
    static func fetchAccount() async -> Account {
        guard let token = ProviderKeychain.read(account: "covey.provider.glm"), !token.isEmpty else {
            return Account()
        }
        var req = URLRequest(url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!)
        req.timeoutInterval = 10
        // z.ai's own dashboard sends the raw token, no "Bearer" prefix — a
        // different scheme than the ANTHROPIC_AUTH_TOKEN header claude sends.
        req.setValue(token, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return Account(usageError: "\(status)")
            }
            guard let usage = parseGlmQuota(data) else {
                return Account(usageError: "parse")
            }
            return Account(usage: usage)
        } catch {
            return Account(usageError: "net")
        }
    }
}
