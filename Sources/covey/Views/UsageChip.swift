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

/// Top-bar usage bar: Claude and Codex chips side by side. Claude's error
/// string shows in place of its chip; Codex simply hides when it has no data.
struct UsageChip: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let codexUsage: CodexRateLimitsSnapshot?
    let codexPlan: String?
    let tk: Tokens

    var body: some View {
        // Ticks every minute so countdowns advance even when the snapshot is
        // Equatable-equal (no re-render otherwise).
        TimelineView(.everyMinute) { ctx in
            let claude = claudeChip(usage: usage, plan: plan)
            let codex = codexChip(snapshot: codexUsage, plan: codexPlan)
            let leftPresent = claude != nil || error != nil
            HStack(spacing: 12) {
                if let claude {
                    AgentChipView(chip: claude, color: tk.claudeBrand, now: ctx.date, tk: tk)
                } else if let error {
                    Text("usage: \(error)").foregroundStyle(.orange)
                }
                // Hairline divider — only when both sides are actually present.
                if leftPresent, codex != nil {
                    Rectangle().fill(tk.bd3).frame(width: 1, height: 12)
                }
                if let codex {
                    AgentChipView(chip: codex, color: tk.codexBrand, now: ctx.date, tk: tk)
                }
            }
        }
    }
}

/// Renders one AgentUsageChip: colored name, muted plan, threshold-colored
/// window pills.
struct AgentChipView: View {
    let chip: AgentUsageChip
    let color: Color
    let now: Date
    let tk: Tokens

    var body: some View {
        HStack(spacing: 8) {
            Text(chip.name).foregroundStyle(color)
            if let plan = chip.plan { Text(plan).foregroundStyle(tk.t3) }
            ForEach(Array(chip.windows.enumerated()), id: \.offset) { entry in
                pill(entry.element.label, entry.element.window)
            }
        }
    }

    private func levelColor(_ pct: Int) -> Color {
        switch usageLevel(pct) {
        case .ok: return tk.ok
        case .warn: return tk.warn
        case .err: return tk.err
        }
    }

    private func pill(_ prefix: String, _ w: UsageWindow) -> some View {
        let pct = Int(w.utilization.rounded())
        let pctText = Text("\(pct)%").foregroundStyle(levelColor(pct))
        let text: Text
        if let reset = w.resetUnix {
            text = Text("\(prefix) \(pctText) · \(remainingLabel(resetUnix: reset, now: now))")
        } else {
            text = Text("\(prefix) \(pctText)")
        }
        return text.foregroundStyle(tk.t3)
    }
}
