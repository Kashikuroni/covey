import SwiftUI
import CoveyKit

/// Pure formatting helpers for the trace panel (unit-tested).
enum TraceRow {
    static func summary(_ e: TraceEvent) -> String {
        switch e.kind {
        case .turnStarted: return "turn started"
        case .turnCompleted: return "turn completed"
        case .assistantText(let p): return p
        case .thinking(let p): return "thinking: \(p)"
        case .toolCall(_, let name): return name
        case .toolResult(_, let isError, let p): return (isError ? "✗ " : "✓ ") + p
        case .fileEdit(let path, let a, let r, _): return "edit \(path) +\(a) −\(r)"
        case .tokenUsage(let u): return "tokens Δ\(u.total)"
        case .rateLimit(let pct, _, _): return "rate \(Int(pct))%"
        case .webSearch(let q): return "search \(q ?? "")"
        case .other(let l): return l
        }
    }

    static func formatBytes(_ n: Int) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let d = Double(n)
        if d >= gb { return String(format: "%.1f GB", d / gb) }
        if d >= mb { return String(format: "%.1f MB", d / mb) }
        if d >= kb { return String(format: "%.1f KB", d / kb) }
        return "\(n) B"
    }

    static func agents(_ events: [TraceEvent]) -> [TraceEvent.AgentRef] {
        var seen = Set<TraceEvent.AgentRef>()
        var out: [TraceEvent.AgentRef] = []
        for a in ([.main] + events.map(\.agent)) where !seen.contains(a) {
            seen.insert(a); out.append(a)
        }
        return out
    }
}

/// Right-drawer agent trace: header (title + store size), agent filter, and a
/// scrolling list of events each expandable to its full source JSON.
struct TracePane: View {
    @Bindable var model: AppModel
    @State private var expanded: Set<Int> = []
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                zoneTitle("Trace", badge: 6, active: model.focus == .inspector, tk: tk)
                Spacer()
                Text(TraceRow.formatBytes(model.traceStoreBytes))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3).background(tk.surface)

            let agents = TraceRow.agents(model.traceEvents)
            if agents.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agents, id: \.self) { a in
                            let selected = model.traceAgentFilter == a
                                || (a.id == nil && model.traceAgentFilter == nil)
                            Button(a.label ?? "main") {
                                model.setTraceAgentFilter(a.id == nil ? nil : a)
                            }
                            .buttonStyle(.plain).font(.caption2)
                            .foregroundStyle(selected ? tk.accent : tk.t4)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 2)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visibleTraceEvents, id: \.seq) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(e.cli == .claudeCode ? "C" : "Cx")
                                    .font(.caption2).foregroundStyle(tk.t4)
                                if let m = e.model {
                                    Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(TraceRow.summary(e)).font(.caption).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(e.seq) }
                            if expanded.contains(e.seq) {
                                Text(e.raw)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled).foregroundStyle(.secondary)
                                    .padding(6).background(tk.surface)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func toggle(_ seq: Int) {
        if expanded.contains(seq) { expanded.remove(seq) } else { expanded.insert(seq) }
    }
}
