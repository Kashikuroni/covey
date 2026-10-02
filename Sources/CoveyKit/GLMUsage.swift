import Foundation

/// Keychain account holding the z.ai API key. Shared with the retired GLM
/// provider profile so a key stored before the retirement keeps working;
/// both the daemon's fetcher and the limits window read/write this item.
public let glmKeychainAccount = "covey.provider.glm"

/// One normalized z.ai quota window, in the provider's own units (credits).
/// `resetAt` keeps the API's Unix milliseconds; display converts to seconds.
public struct GLMLimitWindow: Codable, Equatable, Sendable {
    public init(total: Double, used: Double, remaining: Double,
                usedPercent: Double, remainingPercent: Double, resetAt: Int64) {
        self.total = total
        self.used = used
        self.remaining = remaining
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }
    public var total: Double
    public var used: Double
    public var remaining: Double
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetAt: Int64            // Unix ms, from `nextResetTime`

    enum CodingKeys: String, CodingKey {
        case total, used, remaining
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetAt = "reset_at"
    }
}

/// The two quota windows the z.ai monitor reports: a short rolling window
/// and a weekly one. Either may be absent from a response.
public struct GLMLimits: Codable, Equatable, Sendable {
    public init(fiveHours: GLMLimitWindow? = nil, weekly: GLMLimitWindow? = nil) {
        self.fiveHours = fiveHours
        self.weekly = weekly
    }
    public var fiveHours: GLMLimitWindow?
    public var weekly: GLMLimitWindow?
    var isEmpty: Bool { fiveHours == nil && weekly == nil }

    enum CodingKeys: String, CodingKey {
        case fiveHours = "five_hours"
        case weekly
    }
}

/// Normalized `/api/monitor/usage/quota/limit` result.
public struct GLMQuota: Codable, Equatable, Sendable {
    public init(plan: String, limits: GLMLimits) {
        self.plan = plan
        self.limits = limits
    }
    public var plan: String              // account level, e.g. "max"
    public var limits: GLMLimits
}

/// One GLM poll cycle, mirroring Claude's `Account`: quota and error are
/// independent so a failed fetch keeps the last good snapshot.
public struct GLMAccount: Equatable, Sendable {
    public init(quota: GLMQuota? = nil, error: String? = nil) {
        self.quota = quota
        self.error = error
    }
    public var quota: GLMQuota?
    public var error: String?
}

private func num(_ dict: [String: Any], _ keys: [String]) -> Double? {
    for k in keys {
        if let n = dict[k] as? NSNumber { return n.doubleValue }
        if let d = dict[k] as? Double { return d }
        if let i = dict[k] as? Int { return Double(i) }
    }
    return nil
}

/// One `data.limits` entry → normalized window, or nil when the entry is
/// unusable (bad percentage, missing reset). Numbers are validated like the
/// Claude/Codex parsers so a malformed response cannot fabricate a quota.
private func parseWindow(_ dict: [String: Any]) -> GLMLimitWindow? {
    guard let percent = num(dict, ["percentage"]), validUsagePercentage(percent),
          let total = num(dict, ["usage"]), total.isFinite, total >= 0,
          let used = num(dict, ["currentValue"]), used.isFinite, used >= 0,
          let remaining = num(dict, ["remaining"]), remaining.isFinite, remaining >= 0,
          let resetMs = num(dict, ["nextResetTime"]).flatMap({ usageInteger($0, as: Int64.self) })
    else { return nil }
    return GLMLimitWindow(total: total, used: used, remaining: remaining,
                          usedPercent: percent, remainingPercent: 100 - percent,
                          resetAt: resetMs)
}

/// z.ai identifies a window by (`unit`, `number`): (3, 5) is the rolling
/// 5-hour window, (6, 1) the weekly one. Everything else is ignored.
private func windowSlot(unit: Double, number: Double) -> WritableKeyPath<GLMLimits, GLMLimitWindow?>? {
    switch (usageInteger(unit, as: Int.self), usageInteger(number, as: Int.self)) {
    case (3?, 5?): return \.fiveHours
    case (6?, 1?): return \.weekly
    default: return nil
    }
}

/// Parses the quota/limit response body. Returns nil when the body is not
/// JSON, carries no plan, or yields no usable window — callers keep the last
/// known good snapshot instead.
public func parseGLMQuota(_ body: Data) -> GLMQuota? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let data = root["data"] as? [String: Any],
          let level = data["level"] as? String, !level.isEmpty else { return nil }
    var limits = GLMLimits()
    for entry in data["limits"] as? [[String: Any]] ?? [] {
        guard entry["type"] as? String == "CREDIT_LIMIT",
              let unit = num(entry, ["unit"]),
              let number = num(entry, ["number"]),
              let slot = windowSlot(unit: unit, number: number),
              let window = parseWindow(entry) else { continue }
        limits[keyPath: slot] = window
    }
    guard !limits.isEmpty else { return nil }
    return GLMQuota(plan: level, limits: limits)
}
