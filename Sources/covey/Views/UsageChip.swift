import SwiftUI

/// "2h13m" until the window resets; ceils so it never understates.
func remainingLabel(resetUnix: Int64, now: Date) -> String {
    let current = Int64(now.timeIntervalSince1970)
    if resetUnix <= current { return "0m" }
    let (secs, overflow) = resetUnix.subtractingReportingOverflow(current)
    guard !overflow else { return "—" }
    let mins = secs / 60 + (secs % 60 == 0 ? 0 : 1)
    if mins < 60 { return "\(mins)m" }
    let hours = mins / 60
    if hours < 24 {
        let m = mins % 60
        return m == 0 ? "\(hours)h" : "\(hours)h\(m)m"
    }
    let days = hours / 24
    let h = hours % 24
    return h == 0 ? "\(days)d" : "\(days)d\(h)h"
}

/// amux CLI thresholds: the percentage colors by how burnt the window is.
enum UsageLevel: Equatable { case ok, warn, err }

/// Old on-disk caches predate parser validation. Reject unsafe conversions,
/// while preserving real over-limit values such as 104%.
func displayUsagePercent(_ utilization: Double) -> Int? {
    guard utilization.isFinite, utilization >= 0 else { return nil }
    return Int(exactly: utilization.rounded())
}
func usageLevel(_ pct: Int) -> UsageLevel {
    if pct >= 80 { return .err }
    if pct >= 50 { return .warn }
    return .ok
}

/// Threshold color for a usage level.
func levelColor(_ level: UsageLevel, tk: Tokens) -> Color {
    switch level {
    case .ok: return tk.ok
    case .warn: return tk.warn
    case .err: return tk.err
    }
}

/// One agent's chip contents: colored name + plan badge + labeled windows.
struct AgentUsageChip: Equatable {
    let name: String
    let plan: String?
    let windows: [LabeledWindow]
}

/// GLM chip from the normalized quota: the two windows share the chip
/// renderer, so each becomes a labeled `UsageWindow` — percent straight from
/// `used_percent`, `reset_at` ms converted to Unix seconds.
func glmChip(quota: GLMQuota?) -> AgentUsageChip? {
    guard let quota else { return nil }
    var windows: [LabeledWindow] = []
    if let w = quota.limits.fiveHours {
        windows.append(LabeledWindow(label: "5h", window: w.usageWindow))
    }
    if let w = quota.limits.weekly {
        windows.append(LabeledWindow(label: "7d", window: w.usageWindow))
    }
    guard !windows.isEmpty else { return nil }
    return AgentUsageChip(name: "GLM", plan: glmPlanLabel(quota.plan), windows: windows)
}

extension GLMLimitWindow {
    /// Adapter into the shared renderer: percent used + Unix-seconds reset.
    var usageWindow: UsageWindow {
        UsageWindow(utilization: usedPercent,
                    resetUnix: usageInteger(Double(resetAt) / 1000, as: Int64.self))
    }
}

/// `level` → badge: "max" → "Max" (same capitalization rule as Codex plans).
func glmPlanLabel(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    return raw.prefix(1).uppercased() + raw.dropFirst()
}

/// The 7d takeover cadence: 30 s of 7d every 3 minutes (a 210 s cycle), so a
/// burnt week surfaces without stacking a second 5h/7d row in the header.
func weeklyBlinkActive(now: Date) -> Bool {
    Int(now.timeIntervalSince1970) % 210 < 30
}

private func isRedWindow(_ window: UsageWindow) -> Bool {
    displayUsagePercent(window.utilization).map { usageLevel($0) == .err } ?? false
}

/// The ONE window a provider's header slot shows: the 5h window normally; a
/// red (≥80 %) 7d window takes the slot while the blink phase is active; a
/// lone 7d window keeps the slot permanently.
func headerWindow(fiveHour: UsageWindow?, sevenDay: UsageWindow?,
                  blinkActive: Bool) -> (label: String?, window: UsageWindow?) {
    switch (fiveHour, sevenDay) {
    case (nil, nil):
        return (nil, nil)
    case (nil, let seven?):
        return ("7d", seven)
    case (_?, let seven?) where blinkActive && isRedWindow(seven):
        return ("7d", seven)
    case (let five?, _):
        return ("5h", five)
    }
}

/// The most-used Codex window across every rate-limit bucket. The compact
/// header has one Codex slot, so it surfaces whichever limit is closest.
func codexHeaderWindow(_ snapshot: CodexRateLimitsSnapshot?) -> UsageWindow? {
    snapshot?.windows.max {
        $0.window.utilization < $1.window.utilization
    }?.window
}

/// Codex's 5h and 7d windows across buckets (labels end in "5h"/"7d"; foreign
/// buckets carry a "name 5h" prefix). A multi-bucket snapshot keeps the most
/// burnt window of each kind. Exotic labels match neither and fall back to
/// `codexHeaderWindow`, unlabeled.
func codexHeaderWindows(_ snapshot: CodexRateLimitsSnapshot?)
    -> (fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
    guard let snapshot else { return (nil, nil) }
    var five: UsageWindow?
    var seven: UsageWindow?
    for labeled in snapshot.windows {
        if labeled.label.hasSuffix("5h"),
           (five?.utilization ?? -1) < labeled.window.utilization {
            five = labeled.window
        } else if labeled.label.hasSuffix("7d"),
                  (seven?.utilization ?? -1) < labeled.window.utilization {
            seven = labeled.window
        }
    }
    return (five, seven)
}

/// One compact top-bar segment: a provider label, the window tag it is
/// showing ("5h"/"7d"; nil when the label is exotic or there is no data),
/// and a threshold-colored percent — or a neutral em dash with no snapshot.
struct HeaderSegment: Equatable {
    let label: String
    let windowTag: String?
    let value: String
    let level: UsageLevel?
}

/// Claude, Codex, and GLM segments for the compact header, in display order.
/// Only providers enabled in settings occupy the bar, and each shows ONE
/// window: 5h normally, with a red 7d taking the slot for a 30 s blink every
/// 3 minutes (a lone 7d window is permanent) — no stacked 5h/7d rows.
func headerSegments(usage: Usage?, usageError: String?,
                    codexUsage: CodexRateLimitsSnapshot?,
                    glmQuota: GLMQuota? = nil, glmEnabled: Bool = true,
                    claudeEnabled: Bool = true, codexEnabled: Bool = true,
                    now: Date = Date()) -> [HeaderSegment] {
    let blink = weeklyBlinkActive(now: now)
    func segment(_ label: String, _ pick: (label: String?, window: UsageWindow?)) -> HeaderSegment {
        guard let window = pick.window, let pct = displayUsagePercent(window.utilization) else {
            return HeaderSegment(label: label, windowTag: nil, value: "—", level: nil)
        }
        return HeaderSegment(label: label, windowTag: pick.label,
                             value: "\(pct)%", level: usageLevel(pct))
    }
    let codexPair = codexHeaderWindows(codexUsage)
    let codexPick = headerWindow(fiveHour: codexPair.fiveHour,
                                 sevenDay: codexPair.sevenDay, blinkActive: blink)
    let codex = codexPick.window != nil
        ? codexPick
        : (label: nil, window: codexHeaderWindow(codexUsage))   // exotic labels
    var segments: [HeaderSegment] = []
    if claudeEnabled {
        segments.append(segment("Claude", headerWindow(fiveHour: usage?.fiveHour,
                                                       sevenDay: usage?.sevenDay,
                                                       blinkActive: blink)))
    }
    if codexEnabled {
        segments.append(segment("Codex", codex))
    }
    if glmEnabled {
        segments.append(segment("GLM", headerWindow(
            fiveHour: glmQuota?.limits.fiveHours?.usageWindow,
            sevenDay: glmQuota?.limits.weekly?.usageWindow,
            blinkActive: blink)))
    }
    return segments
}

/// Localized "24 июля · 14:32" — day + full month name (in whatever case
/// the locale's grammar requires, via ICU template resolution) and 24-hour
/// time, no year.
func headerDateTime(_ date: Date, locale: Locale = .current) -> String {
    let dayMonth = DateFormatter()
    dayMonth.locale = locale
    dayMonth.setLocalizedDateFormatFromTemplate("d MMMM")
    let time = DateFormatter()
    time.locale = locale
    time.dateFormat = "HH:mm"
    return "\(dayMonth.string(from: date)) · \(time.string(from: date))"
}

/// Compact top-bar group: Claude %, Codex %, date/time, hairline-divided.
/// Full per-window detail opens through `Show Limits Detail` in the command palette.
struct UsageChip: View {
    let usage: Usage?
    let usageError: String?
    let codexUsage: CodexRateLimitsSnapshot?
    var glmQuota: GLMQuota? = nil
    var glmEnabled: Bool = true
    var claudeEnabled: Bool = true
    var codexEnabled: Bool = true
    let tk: Tokens
    /// Клик по часам: открывает модалку провайдеров.
    var onClockTap: (() -> Void)? = nil

    var body: some View {
        // Ticks every 2 s: the clock advances, and the 30-s 7d blink phase
        // must switch in and out even while snapshots are Equatable-equal.
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let segments = headerSegments(usage: usage, usageError: usageError,
                                          codexUsage: codexUsage,
                                          glmQuota: glmQuota, glmEnabled: glmEnabled,
                                          claudeEnabled: claudeEnabled,
                                          codexEnabled: codexEnabled, now: ctx.date)
            HStack(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    if index > 0 { divider }
                    segmentView(seg)
                }
                if !segments.isEmpty { divider }
                Text(headerDateTime(ctx.date)).foregroundStyle(tk.t3)
            }
            .contentShape(Rectangle())
            .onTapGesture { onClockTap?() }
            .help("Providers")
        }
    }

    private var divider: some View {
        Rectangle().fill(tk.bd3).frame(width: 1, height: 12)
    }

    @ViewBuilder
    private func segmentView(_ seg: HeaderSegment) -> some View {
        HStack(spacing: 6) {
            Text(seg.label).foregroundStyle(brandColor(seg.label))
            if let tag = seg.windowTag {
                Text(tag).foregroundStyle(tk.t3)
            }
            if let level = seg.level {
                Text(seg.value).foregroundStyle(levelColor(level, tk: tk))
            } else {
                Text(seg.value).foregroundStyle(tk.t3)
            }
        }
    }

    private func brandColor(_ label: String) -> Color {
        switch label {
        case "Codex": return tk.codexBrand
        case "GLM": return tk.glmBrand
        default: return tk.claudeBrand
        }
    }
}
