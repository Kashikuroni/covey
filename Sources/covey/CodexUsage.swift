import Foundation

/// One labeled usage window (Codex primary/secondary), reusing the Claude
/// `UsageWindow` so the chip renderer stays shared.
struct LabeledWindow: Equatable {
    let label: String
    let window: UsageWindow
}

/// Codex account identity from `account/read`. Only `chatgpt` carries
/// subscription rate limits; `apiKey` (or anything else) means no chip.
struct CodexAccount: Equatable {
    var type: String
    var planType: String?
}

/// One Codex rate-limit bucket. Keyed by upstream limit ID so partial
/// `updated` events merge unambiguously regardless of display label.
struct CodexRateLimitBucket: Equatable {
    let id: String
    let name: String?
    var primary: LabeledWindow?
    var secondary: LabeledWindow?

    private var windowPrefix: String? {
        guard id != "codex" else { return nil }
        guard let name, !name.isEmpty else { return id }
        if name.localizedCaseInsensitiveContains("spark") { return "Spark" }
        return name
    }

    var windows: [LabeledWindow] {
        [primary, secondary].compactMap { labeled in
            guard let labeled else { return nil }
            guard let windowPrefix else { return labeled }
            return LabeledWindow(label: "\(windowPrefix) \(labeled.label)",
                                 window: labeled.window)
        }
    }
}

struct CodexRateLimitsSnapshot: Equatable {
    var buckets: [String: CodexRateLimitBucket]

    init(buckets: [String: CodexRateLimitBucket]) {
        self.buckets = buckets
    }

    init(primary: LabeledWindow?, secondary: LabeledWindow?) {
        buckets = ["codex": CodexRateLimitBucket(id: "codex", name: nil,
                                                   primary: primary, secondary: secondary)]
    }

    private var legacyBucket: CodexRateLimitBucket? {
        buckets["codex"] ?? buckets.sorted { $0.key < $1.key }.first?.value
    }

    var primary: LabeledWindow? { legacyBucket?.primary }
    var secondary: LabeledWindow? { legacyBucket?.secondary }

    var windows: [LabeledWindow] {
        buckets.values.sorted {
            if $0.id == "codex" { return true }
            if $1.id == "codex" { return false }
            return $0.id < $1.id
        }.flatMap(\.windows)
    }
}

/// Compact label from a window duration: 300→"5h", 10080→"7d", 90→"90m".
func codexWindowLabel(minutes: Int) -> String {
    if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    return "\(minutes)m"
}

/// planType → badge: "plus"→"Plus". Unknown non-empty → capitalized as-is.
func codexPlanLabel(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw.prefix(1).uppercased() + raw.dropFirst()
}

/// First numeric value under any of the candidate keys (camel/snake tolerant).
private func num(_ dict: [String: Any], _ keys: [String]) -> Double? {
    for k in keys {
        if let n = dict[k] as? NSNumber { return n.doubleValue }
        if let d = dict[k] as? Double { return d }
        if let i = dict[k] as? Int { return Double(i) }
    }
    return nil
}

private func str(_ dict: [String: Any], _ keys: [String]) -> String? {
    for k in keys where dict[k] is String { return dict[k] as? String }
    return nil
}

func parseCodexAccount(_ json: [String: Any]) -> CodexAccount? {
    guard let acc = json["account"] as? [String: Any],
          let type = str(acc, ["type"]) else { return nil }
    return CodexAccount(type: type, planType: str(acc, ["planType", "plan_type"]))
}

private func parseWindow(_ dict: [String: Any], fallbackLabel: String) -> LabeledWindow? {
    guard let used = num(dict, ["usedPercent", "used_percent"]) else { return nil }
    let mins = num(dict, ["windowDurationMins", "window_duration_mins"]).map { Int($0) }
    let reset = num(dict, ["resetsAt", "resets_at"]).map { Int64($0) }
    let label = mins.map(codexWindowLabel(minutes:)) ?? fallbackLabel
    return LabeledWindow(label: label,
                         window: UsageWindow(utilization: used, resetUnix: reset))
}

private func parseBucket(_ dict: [String: Any], fallbackID: String) -> CodexRateLimitBucket? {
    let primary = (dict["primary"] as? [String: Any])
        .flatMap { parseWindow($0, fallbackLabel: "primary") }
    let secondary = (dict["secondary"] as? [String: Any])
        .flatMap { parseWindow($0, fallbackLabel: "secondary") }
    guard primary != nil || secondary != nil else { return nil }
    let id = str(dict, ["limitId", "limit_id"]) ?? fallbackID
    return CodexRateLimitBucket(id: id,
                                name: str(dict, ["limitName", "limit_name"]),
                                primary: primary,
                                secondary: secondary)
}

/// Accepts the current multi-bucket response, the legacy `rateLimits` wrapper,
/// or a bucket directly.
func parseCodexRateLimits(_ json: [String: Any]) -> CodexRateLimitsSnapshot? {
    if let byID = json["rateLimitsByLimitId"] as? [String: Any] {
        var buckets: [String: CodexRateLimitBucket] = [:]
        for (fallbackID, value) in byID {
            guard let dict = value as? [String: Any],
                  let bucket = parseBucket(dict, fallbackID: fallbackID) else { continue }
            buckets[bucket.id] = bucket
        }
        if !buckets.isEmpty { return CodexRateLimitsSnapshot(buckets: buckets) }
    }

    let bucket = (json["rateLimits"] as? [String: Any]) ?? json
    guard let parsed = parseBucket(bucket, fallbackID: "codex") else { return nil }
    return CodexRateLimitsSnapshot(buckets: [parsed.id: parsed])
}

/// Partial `updated` merges into the last full snapshot: a nil slot in the
/// update keeps the base slot (missing fields are not zeroed).
func mergeCodex(into base: CodexRateLimitsSnapshot?,
                update: CodexRateLimitsSnapshot) -> CodexRateLimitsSnapshot {
    guard let base else { return update }
    var buckets = base.buckets
    for (id, updateBucket) in update.buckets {
        guard let baseBucket = buckets[id] else {
            buckets[id] = updateBucket
            continue
        }
        buckets[id] = CodexRateLimitBucket(
            id: id,
            name: updateBucket.name ?? baseBucket.name,
            primary: updateBucket.primary ?? baseBucket.primary,
            secondary: updateBucket.secondary ?? baseBucket.secondary)
    }
    return CodexRateLimitsSnapshot(buckets: buckets)
}
