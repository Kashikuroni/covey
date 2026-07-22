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

/// Latest Codex rate-limit snapshot. Keyed by slot (primary/secondary) so a
/// partial `updated` event merges unambiguously regardless of display label.
struct CodexRateLimitsSnapshot: Equatable {
    var primary: LabeledWindow?
    var secondary: LabeledWindow?
    var windows: [LabeledWindow] { [primary, secondary].compactMap { $0 } }
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

/// Accepts either a `{"rateLimits": {...}}` wrapper or the bucket directly.
func parseCodexRateLimits(_ json: [String: Any]) -> CodexRateLimitsSnapshot? {
    let bucket = (json["rateLimits"] as? [String: Any]) ?? json
    let primary = (bucket["primary"] as? [String: Any])
        .flatMap { parseWindow($0, fallbackLabel: "primary") }
    let secondary = (bucket["secondary"] as? [String: Any])
        .flatMap { parseWindow($0, fallbackLabel: "secondary") }
    guard primary != nil || secondary != nil else { return nil }
    return CodexRateLimitsSnapshot(primary: primary, secondary: secondary)
}

/// Partial `updated` merges into the last full snapshot: a nil slot in the
/// update keeps the base slot (missing fields are not zeroed).
func mergeCodex(into base: CodexRateLimitsSnapshot?,
                update: CodexRateLimitsSnapshot) -> CodexRateLimitsSnapshot {
    guard let base else { return update }
    return CodexRateLimitsSnapshot(primary: update.primary ?? base.primary,
                                   secondary: update.secondary ?? base.secondary)
}
