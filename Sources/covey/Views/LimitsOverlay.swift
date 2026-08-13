import SwiftUI

/// Maps `UsagePlacement` to a top-anchored overlay alignment — `LimitsOverlay`
/// always opens directly under wherever the compact header currently sits.
func topOverlayAlignment(_ placement: UsagePlacement) -> Alignment {
    switch placement {
    case .left: return .topLeading
    case .center: return .top
    case .right: return .topTrailing
    }
}

/// Command palette detail popover: full Claude/Codex breakdown (plan + every
/// window + reset countdown + a threshold-colored progress bar), glass-styled
/// like `HelpOverlay`. Layout follows the "AI Limits Panel"
/// design mockup; colors come from `Tokens` instead of the mockup's own
/// palette, and the per-provider switch is the native `Toggle` tinted with
/// `tk.accent` rather than the mockup's hand-drawn pill.
struct LimitsOverlay: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let codexUsage: CodexRateLimitsSnapshot?
    let codexPlan: String?
    let glmUsage: Usage?
    let glmError: String?
    let claudeUsageEnabled: Bool
    let codexUsageEnabled: Bool
    let glmUsageEnabled: Bool
    let onSetClaudeUsageEnabled: (Bool) -> Void
    let onSetCodexUsageEnabled: (Bool) -> Void
    let onSetGlmUsageEnabled: (Bool) -> Void
    let selectedProvider: AppModel.LimitsProvider
    let tk: Tokens

    private let cardWidth: CGFloat = 320

    private var rows: [LimitsRowModel] {
        limitsRows(usage: usage, plan: plan, error: error,
                   codexUsage: codexUsage, codexPlan: codexPlan,
                   glmUsage: glmUsage, glmError: glmError,
                   claudeEnabled: claudeUsageEnabled,
                   codexEnabled: codexUsageEnabled,
                   glmEnabled: glmUsageEnabled)
    }

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(now: ctx.date)
                ForEach(rows) { row in
                    providerSection(row: row, now: ctx.date)
                }
            }
            .frame(width: cardWidth)
            // Tinted with our own surface color so whatever sits behind the
            // popover (terminal text, in particular) doesn't bleed through
            // enough to fight the card's own text for legibility.
            .glassEffect(.regular.tint(tk.surface.opacity(0.6)), in: .rect(cornerRadius: 16))
            .shadow(radius: 12)
        }
    }

    private func cardHeader(now: Date) -> some View {
        HStack {
            Text("AI Usage Limits")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(tk.t3)
            Spacer()
            Text(headerDateTime(now))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tk.t3)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private func providerSection(row: LimitsRowModel, now: Date) -> some View {
        let selected = isSelected(row.provider)
        let onSetEnabled = enabledSetter(row.provider)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(row.chip.name)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? tk.accent : tk.t1)
                if let plan = row.chip.plan {
                    Text(plan)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tk.t2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tk.surf2, in: Capsule())
                }
                if row.stale { Text("*").foregroundStyle(tk.warn) }
                Spacer()
                Toggle("", isOn: Binding(get: { row.enabled }, set: onSetEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(tk.accent)
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }
            .opacity(row.enabled ? 1 : 0.55)
            ForEach(Array(row.chip.windows.enumerated()), id: \.offset) { entry in
                windowRow(entry.element, now: now)
            }
            .opacity(row.enabled ? 1 : 0.55)
            if let message = row.emptyMessage {
                Text(message)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(message == "No usage data" ? tk.t3 : tk.warn)
                    .opacity(row.enabled ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(tk.bd2).frame(height: 1) }
    }

    private func isSelected(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .claude: return selectedProvider == .claude
        case .codex: return selectedProvider == .codex
        case .glm: return selectedProvider == .glm
        }
    }

    private func enabledSetter(_ provider: UsageProvider) -> (Bool) -> Void {
        switch provider {
        case .claude: return onSetClaudeUsageEnabled
        case .codex: return onSetCodexUsageEnabled
        case .glm: return onSetGlmUsageEnabled
        }
    }

    private func windowRow(_ w: LabeledWindow, now: Date) -> some View {
        let pct = Int(w.window.utilization.rounded())
        let color = levelColor(usageLevel(pct), tk: tk)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(w.label)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tk.t1)
                if let reset = w.window.resetUnix {
                    Text("resets in \(remainingLabel(resetUnix: reset, now: now))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(tk.t2)
                }
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tk.surf2)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(pct) / 100)
                }
            }
            .frame(height: 6)
        }
    }
}
