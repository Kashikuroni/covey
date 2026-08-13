import SwiftUI

/// "2h13m" until the window resets; ceils so it never understates.
func remainingLabel(resetUnix: Int64, now: Date) -> String {
    let secs = resetUnix - Int64(now.timeIntervalSince1970)
    if secs <= 0 { return "0m" }
    let mins = (secs + 59) / 60
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

/// A plan badge that just repeats the agent name is noise — the generic
/// "Claude" fallback (unrecognized rate_limit_tier) collides with the name
/// label. Drop it in that case.
private func distinctPlan(_ plan: String?, name: String) -> String? {
    guard let plan, plan.caseInsensitiveCompare(name) != .orderedSame else { return nil }
    return plan
}

/// Claude chip from the polled Usage (nil when there's no usage snapshot).
func claudeChip(usage: Usage?, plan: String?) -> AgentUsageChip? {
    guard let usage else { return nil }
    var windows: [LabeledWindow] = []
    if let w = usage.fiveHour { windows.append(LabeledWindow(label: "5h", window: w)) }
    if let w = usage.sevenDay { windows.append(LabeledWindow(label: "7d", window: w)) }
    if let w = usage.sevenDaySonnet { windows.append(LabeledWindow(label: "S 7d", window: w)) }
    return AgentUsageChip(name: "Claude", plan: distinctPlan(plan, name: "Claude"),
                          windows: windows)
}

/// Codex chip from the latest merged snapshot (nil when there are no windows).
func codexChip(snapshot: CodexRateLimitsSnapshot?, plan: String?) -> AgentUsageChip? {
    guard let snapshot, !snapshot.windows.isEmpty else { return nil }
    return AgentUsageChip(name: "Codex", plan: distinctPlan(plan, name: "Codex"),
                          windows: snapshot.windows)
}

/// GLM chip from the polled 5h-token Usage (nil when there's no snapshot).
/// z.ai's quota endpoint carries no plan/tier name, so there is no plan badge.
func glmChip(usage: Usage?) -> AgentUsageChip? {
    guard let usage, let window = usage.fiveHour else { return nil }
    return AgentUsageChip(name: "GLM", plan: nil, windows: [LabeledWindow(label: "5h", window: window)])
}

/// The Codex window to treat as "current session" in the compact header:
/// the window labeled `7d`, falling back to `secondary` then `primary` —
/// tolerant of the same missing-duration cases `codexChip` already is.
func codexHeaderWindow(_ snapshot: CodexRateLimitsSnapshot?) -> UsageWindow? {
    guard let snapshot else { return nil }
    if let sevenDay = snapshot.windows.first(where: { $0.label == "7d" }) {
        return sevenDay.window
    }
    return (snapshot.secondary ?? snapshot.primary)?.window
}

/// One compact top-bar segment: a provider label with its threshold-colored
/// percent, or a neutral em dash while no usage snapshot is available.
struct HeaderSegment: Equatable {
    let label: String
    let value: String
    let level: UsageLevel?
}

/// Claude, Codex, and GLM segments for the compact header, in display order.
/// The three slots are stable; a provider without data shows an em dash.
func headerSegments(usage: Usage?, usageError: String?,
                    codexUsage: CodexRateLimitsSnapshot?,
                    glmUsage: Usage? = nil) -> [HeaderSegment] {
    func segment(_ label: String, _ window: UsageWindow?) -> HeaderSegment {
        guard let window else {
            return HeaderSegment(label: label, value: "—", level: nil)
        }
        let pct = Int(window.utilization.rounded())
        return HeaderSegment(label: label, value: "\(pct)%", level: usageLevel(pct))
    }
    return [
        segment("Claude", usage?.fiveHour),
        segment("Codex", codexHeaderWindow(codexUsage)),
        segment("GLM", glmUsage?.fiveHour),
    ]
}

enum UsageProvider: Equatable, CaseIterable {
    case claude, codex, glm
}

/// Stable provider row for the limits detail popover. A row exists even when
/// its provider has no snapshot, in which case `emptyMessage` explains why.
struct LimitsRowModel: Equatable, Identifiable {
    var id: UsageProvider { provider }
    let provider: UsageProvider
    let chip: AgentUsageChip
    let enabled: Bool
    let stale: Bool
    let emptyMessage: String?
}

func limitsRows(usage: Usage?, plan: String?, error: String?,
                codexUsage: CodexRateLimitsSnapshot?, codexPlan: String?,
                glmUsage: Usage?, glmError: String?,
                claudeEnabled: Bool, codexEnabled: Bool,
                glmEnabled: Bool) -> [LimitsRowModel] {
    let claude = claudeChip(usage: usage, plan: plan)
        ?? AgentUsageChip(name: "Claude", plan: distinctPlan(plan, name: "Claude"), windows: [])
    let codex = codexChip(snapshot: codexUsage, plan: codexPlan)
        ?? AgentUsageChip(name: "Codex", plan: distinctPlan(codexPlan, name: "Codex"), windows: [])
    let glm = glmChip(usage: glmUsage)
        ?? AgentUsageChip(name: "GLM", plan: nil, windows: [])

    return [
        LimitsRowModel(provider: .claude, chip: claude, enabled: claudeEnabled,
                       stale: error != nil && !claude.windows.isEmpty,
                       emptyMessage: claude.windows.isEmpty ? (error ?? "No usage data") : nil),
        LimitsRowModel(provider: .codex, chip: codex, enabled: codexEnabled,
                       stale: false,
                       emptyMessage: codex.windows.isEmpty ? "No usage data" : nil),
        LimitsRowModel(provider: .glm, chip: glm, enabled: glmEnabled,
                       stale: glmError != nil && !glm.windows.isEmpty,
                       emptyMessage: glm.windows.isEmpty ? (glmError ?? "No usage data") : nil),
    ]
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
    let glmUsage: Usage?
    let tk: Tokens

    var body: some View {
        // Ticks every minute so the clock and countdown-derived data advance
        // even when the snapshot is Equatable-equal (no re-render otherwise).
        TimelineView(.everyMinute) { ctx in
            let segments = headerSegments(usage: usage, usageError: usageError,
                                          codexUsage: codexUsage, glmUsage: glmUsage)
            HStack(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    if index > 0 { divider }
                    segmentView(seg)
                }
                if !segments.isEmpty { divider }
                Text(headerDateTime(ctx.date)).foregroundStyle(tk.t3)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(tk.bd3).frame(width: 1, height: 12)
    }

    @ViewBuilder
    private func segmentView(_ seg: HeaderSegment) -> some View {
        HStack(spacing: 6) {
            Text(seg.label).foregroundStyle(brandColor(seg.label))
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
