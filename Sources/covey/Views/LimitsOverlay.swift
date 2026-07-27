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
struct LimitsOverlay: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let codexUsage: CodexRateLimitsSnapshot?
    let codexPlan: String?
    let tk: Tokens

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let claude = claudeChip(usage: usage, plan: plan)
            let codex = codexChip(snapshot: codexUsage, plan: codexPlan)
            VStack(alignment: .leading, spacing: 10) {
                if let claude {
                    AgentChipView(chip: claude, color: tk.claudeBrand, now: ctx.date, tk: tk)
                } else if let error {
                    Text("usage: \(error)").foregroundStyle(.orange)
                }
                if let codex {
                    AgentChipView(chip: codex, color: tk.codexBrand, now: ctx.date, tk: tk)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .shadow(radius: 10)
        }
    }
}
