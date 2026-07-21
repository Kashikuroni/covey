import SwiftUI

enum UsageChipItem: Equatable {
    case plan(String)
    case window(String, UsageWindow)
}

func usageChipItems(usage: Usage, plan: String?) -> [UsageChipItem] {
    var items: [UsageChipItem] = []

    if let plan { items.append(.plan(plan)) }
    if let window = usage.fiveHour { items.append(.window("5h", window)) }
    if let window = usage.sevenDay { items.append(.window("7d", window)) }
    if let window = usage.sevenDaySonnet { items.append(.window("S 7d", window)) }

    return items
}

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

/// Compact Claude usage chip: windows + plan badge, or an error code.
struct UsageChip: View {
    let usage: Usage?
    let plan: String?
    let error: String?
    let tk: Tokens

    var body: some View {
        if let usage {
            // Ticks every minute: countdowns must advance even when the
            // polled Usage snapshot is Equatable-equal (no re-render).
            TimelineView(.everyMinute) { ctx in
                HStack(spacing: 8) {
                    ForEach(Array(usageChipItems(usage: usage, plan: plan).enumerated()), id: \.offset) { entry in
                        switch entry.element {
                        case .plan(let label):
                            badge(Text(label))
                        case .window(let prefix, let window):
                            pill(prefix, window, now: ctx.date)
                        }
                    }
                }
            }
        } else if let error {
            Text("usage: \(error)").foregroundStyle(.orange)
        } else {
            EmptyView()
        }
    }

    private func levelColor(_ pct: Int) -> Color {
        switch usageLevel(pct) {
        case .ok: return tk.ok
        case .warn: return tk.warn
        case .err: return tk.err
        }
    }

    private func pill(_ prefix: String, _ w: UsageWindow, now: Date) -> some View {
        let pct = Int(w.utilization.rounded())
        let pctText = Text("\(pct)%").foregroundStyle(levelColor(pct))
        let text: Text
        if let reset = w.resetUnix {
            text = Text("\(prefix) \(pctText) · \(remainingLabel(resetUnix: reset, now: now))")
        } else {
            text = Text("\(prefix) \(pctText)")
        }
        return badge(text)
    }

    private func badge(_ text: Text) -> some View {
        // Plain minimal text — no chip chrome. Muted ayu body color; the
        // percentage keeps its own threshold color.
        text.foregroundStyle(tk.t3)
    }
}
