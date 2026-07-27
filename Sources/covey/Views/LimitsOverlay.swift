import SwiftUI

/// Renders one AgentUsageChip: colored name, muted plan, threshold-colored
/// window pills. Used only by the `leader l` detail popover now — the top
/// bar itself shows just the compact percent (see `UsageChip`).
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

    private func pill(_ prefix: String, _ w: UsageWindow) -> some View {
        let pct = Int(w.utilization.rounded())
        let pctText = Text("\(pct)%").foregroundStyle(levelColor(usageLevel(pct), tk: tk))
        let text: Text
        if let reset = w.resetUnix {
            text = Text("\(prefix) \(pctText) · \(remainingLabel(resetUnix: reset, now: now))")
        } else {
            text = Text("\(prefix) \(pctText)")
        }
        return text.foregroundStyle(tk.t3)
    }
}

/// Maps `UsagePlacement` to a top-anchored overlay alignment — `LimitsOverlay`
/// always opens directly under wherever the compact header currently sits.
func topOverlayAlignment(_ placement: UsagePlacement) -> Alignment {
    switch placement {
    case .left: return .topLeading
    case .center: return .top
    case .right: return .topTrailing
    }
}

/// `leader l` detail popover: full Claude/Codex breakdown (plan + every
/// window + reset countdown), glass-styled like `HelpOverlay`/`WhichKeyView`.
/// Each provider row carries its own display/polling toggle — off dims the
/// row and freezes it on the last known snapshot (see
/// `AppModel.setClaudeUsageEnabled`/`setCodexUsageEnabled`).
struct LimitsOverlay: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let codexUsage: CodexRateLimitsSnapshot?
    let codexPlan: String?
    let claudeUsageEnabled: Bool
    let codexUsageEnabled: Bool
    let onSetClaudeUsageEnabled: (Bool) -> Void
    let onSetCodexUsageEnabled: (Bool) -> Void
    let tk: Tokens

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let claude = claudeChip(usage: usage, plan: plan)
            let codex = codexChip(snapshot: codexUsage, plan: codexPlan)
            VStack(alignment: .leading, spacing: 10) {
                if let claude {
                    row(chip: claude, color: tk.claudeBrand, now: ctx.date,
                        enabled: claudeUsageEnabled, stale: error != nil,
                        onSetEnabled: onSetClaudeUsageEnabled)
                } else if let error {
                    Text("usage: \(error)").foregroundStyle(.orange)
                }
                if let codex {
                    // Codex has no separate error signal today (a failed
                    // poll just silently keeps the last snapshot), so only
                    // the disabled state gets a marker here, not staleness.
                    row(chip: codex, color: tk.codexBrand, now: ctx.date,
                        enabled: codexUsageEnabled, stale: false,
                        onSetEnabled: onSetCodexUsageEnabled)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .shadow(radius: 10)
        }
    }

    private func row(chip: AgentUsageChip, color: Color, now: Date,
                      enabled: Bool, stale: Bool,
                      onSetEnabled: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            AgentChipView(chip: chip, color: color, now: now, tk: tk)
                .opacity(enabled ? 1 : 0.4)
            if enabled, stale {
                Text("*").foregroundStyle(tk.warn)
            }
            miniToggle(enabled: enabled, onSetEnabled: onSetEnabled)
        }
    }

    /// A `KbdBadge`-style chip standing in for a checkbox — bordered
    /// monospaced "on"/"off" pill, sized to its own text (no `Toggle`, whose
    /// default macOS checkbox style clashes with the rest of this glass
    /// popover, and no `Spacer`, which would stretch the whole popover to
    /// the window's width instead of hugging its content).
    private func miniToggle(enabled: Bool, onSetEnabled: @escaping (Bool) -> Void) -> some View {
        Text(enabled ? "on" : "off")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(enabled ? tk.t1 : tk.t4)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(enabled ? tk.accent.opacity(0.18) : tk.surf2,
                       in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tk.bd2))
            .contentShape(Rectangle())
            .onTapGesture { onSetEnabled(!enabled) }
    }
}
