import Foundation

public struct UsageWindow: Equatable {
    public var utilization: Double     // 0–100
    public var resetUnix: Int64?       // reset instant, from `resets_at`
}

public struct Usage: Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && sevenDaySonnet == nil }
}

public struct Account: Equatable {
    public var usage: Usage?
    public var plan: String?
    public var usageError: String?
    public init(usage: Usage? = nil, plan: String? = nil, usageError: String? = nil) {
        self.usage = usage; self.plan = plan; self.usageError = usageError
    }
}

/// Parses the `/api/oauth/usage` body. Returns nil if unusable or all
/// windows are null.
func parseUsage(_ body: Data) -> Usage? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return nil
    }
    func window(_ key: String) -> UsageWindow? {
        guard let w = root[key] as? [String: Any],
              let util = w["utilization"] as? Double else { return nil }
        let resetUnix = (w["resets_at"] as? String).flatMap(parseISO8601)
        return UsageWindow(utilization: util, resetUnix: resetUnix)
    }
    let usage = Usage(fiveHour: window("five_hour"),
                      sevenDay: window("seven_day"),
                      sevenDaySonnet: window("seven_day_sonnet"))
    return usage.isEmpty ? nil : usage
}

/// `organization.rate_limit_tier` -> short badge; nil if absent.
func parsePlan(_ body: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let org = root["organization"] as? [String: Any],
          let tier = org["rate_limit_tier"] as? String else { return nil }
    return planLabel(tier)
}

/// Slug -> badge: base (Max/Pro/Team/Enterprise/Claude) + trailing `_Nx` -> "N×".
func planLabel(_ tier: String) -> String {
    let t = tier.lowercased()
    let base: String
    if t.contains("max") { base = "Max" }
    else if t.contains("pro") { base = "Pro" }
    else if t.contains("team") { base = "Team" }
    else if t.contains("enterprise") { base = "Enterprise" }
    else { base = "Claude" }
    // A trailing "_<n>x" segment is the rate multiplier.
    let mult = t.split(separator: "_").reversed().compactMap { seg -> String? in
        guard seg.hasSuffix("x") else { return nil }
        let digits = seg.dropLast()
        return (!digits.isEmpty && digits.allSatisfy(\.isNumber)) ? String(digits) : nil
    }.first
    return mult.map { "\(base) \($0)×" } ?? base
}

/// ISO8601 (e.g. "2026-06-02T10:40:01Z") -> Unix seconds, or nil.
/// The live API appends microseconds ("…T03:49:59.580980+00:00");
/// ISO8601DateFormatter's `.withFractionalSeconds` only takes exactly three
/// digits, so the fraction is stripped instead — seconds are enough here.
func parseISO8601(_ s: String) -> Int64? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let date = f.date(from: trimmed) else { return nil }
    return Int64(date.timeIntervalSince1970)
}
