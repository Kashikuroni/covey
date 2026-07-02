import SwiftUI

/// "5h 77%" or "7d 40% · 10:40" (with reset time when known).
func windowLabel(_ prefix: String, _ w: UsageWindow) -> String {
    let pct = Int(w.utilization.rounded())
    if let reset = w.resetHHMM { return "\(prefix) \(pct)% · \(reset)" }
    return "\(prefix) \(pct)%"
}

/// Whether the chip applies to this session's agent (Claude only).
func isClaudeAgent(_ agent: String) -> Bool {
    agent.lowercased().contains("claude")
}

/// Compact Claude usage chip: windows + plan badge, or an error code.
struct UsageChip: View {
    let usage: Usage?
    let plan: String?
    let error: String?

    var body: some View {
        if let usage {
            HStack(spacing: 8) {
                if let w = usage.fiveHour { pill(windowLabel("5h", w)) }
                if let w = usage.sevenDay { pill(windowLabel("7d", w)) }
                if let w = usage.sevenDaySonnet { pill(windowLabel("S 7d", w)) }
                if let plan { pill(plan).foregroundStyle(.secondary) }
            }
            .font(.caption)
        } else if let error {
            Text("usage: \(error)").font(.caption).foregroundStyle(.orange)
        } else {
            EmptyView()
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
