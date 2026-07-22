import SwiftUI
import CoveyKit

/// Pure formatting helpers for the trace panel (unit-tested).
enum TraceRow {
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

    /// Newest first: the trace grows as a stack (new calls on top, older
    /// below) rather than a top-to-bottom chat log.
    static func displayOrder(_ events: [TraceEvent]) -> [TraceEvent] {
        events.reversed()
    }

    /// Re-serialize a stored raw JSON string as indented, human-readable JSON.
    /// Non-JSON payloads (e.g. a bare shell command) pass through unchanged.
    static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }
}

/// Trace-card syntax colors the shared Ayu tokens don't carry.
private extension Tokens {
    var traceBlue: Color { isDark ? Color(hex: 0x73D0FF) : Color(hex: 0x399EE6) }
    var tracePurple: Color { isDark ? Color(hex: 0xDFBFFF) : Color(hex: 0xA37ACC) }
}

/// Right-drawer agent trace: a stack of typed cards (Bash, Edit split-diff,
/// Read, Usage table, Assistant, Result …), newest on top, each expandable to
/// its detail plus a `{ } source` toggle for the raw JSON.
struct TracePane: View {
    @Bindable var model: AppModel
    @State private var open: Set<Int> = []      // card body expanded
    @State private var src: Set<Int> = []       // raw-JSON source expanded
    @State private var usageOpen = false        // pinned usage bar expanded
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        // Usage and rate-limit readings are ambient state, not steps — pinned at
        // the top, kept out of the card stream.
        let stream = model.visibleTraceEvents.filter {
            TracePresenter.rateLimit($0) == nil && TracePresenter.kind($0) != .usage
        }
        return VStack(spacing: 0) {
            header
            usageBar
            limitBar
            agentFilter
            if stream.isEmpty {
                Text("no activity yet")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(TraceRow.displayOrder(stream), id: \.seq) { e in
                            row(for: e)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(tk.bg)
    }

    /// Thin pinned strip with the newest rate-limit reading; hidden when the
    /// session's CLI never reports limits (e.g. Claude transcripts).
    @ViewBuilder private var limitBar: some View {
        if let rl = TracePresenter.latestRateLimit(model.visibleTraceEvents) {
            let color = rl.percent > 85 ? tk.err : rl.percent > 60 ? tk.wait : tk.ok
            HStack(spacing: 8) {
                Text(rl.plan ?? "limit")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t3)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tk.bd2)
                        Capsule().fill(color)
                            .frame(width: geo.size.width * min(max(rl.percent / 100, 0), 1))
                    }
                }
                .frame(height: 5)
                Text("\(Int(rl.percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(tk.t2)
                if let reset = TracePresenter.resetLabel(rl.resetsAt) {
                    Text("сброс \(reset)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(tk.t4)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(tk.surface)
            .overlay(alignment: .bottom) { tk.bd2.frame(height: 1) }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            zoneTitle("Trace", badge: 6, active: model.focus == .inspector, tk: tk)
            Spacer()
            Text("Ayu \(tk.isDark ? "Dark" : "Light") · \(TraceRow.formatBytes(model.traceStoreBytes))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(tk.t4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tk.surface)
        .overlay(alignment: .bottom) { tk.bd2.frame(height: 1) }
    }

    @ViewBuilder private var agentFilter: some View {
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
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? tk.accent : tk.t4)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(selected ? tk.accent.opacity(0.12) : .clear)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Row dispatch

    @ViewBuilder private func row(for e: TraceEvent) -> some View {
        switch TracePresenter.kind(e) {
        case .thinking, .turn: thinRow(e)
        case .usage: EmptyView()   // shown in the pinned usage bar, not the stream
        default: card(e)
        }
    }

    private func accent(_ e: TraceEvent) -> Color {
        switch TracePresenter.kind(e) {
        case .bash: return tk.run
        case .read, .edit: return tk.traceBlue
        case .usage: return tk.accent
        case .assistant: return tk.tracePurple
        case .result:
            if case let .toolResult(_, isError, _) = e.kind { return isError ? tk.err : tk.ok }
            return tk.ok
        case .generic: return tk.t3
        case .thinking, .turn: return tk.t4
        }
    }

    // MARK: - Card

    private func card(_ e: TraceEvent) -> some View {
        let isOpen = open.contains(e.seq)
        return VStack(alignment: .leading, spacing: 0) {
            cardHeader(e, isOpen: isOpen)
            body(e, isOpen: isOpen)
            sourceToggle(e)
        }
        .background(tk.card)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(tk.bd2, lineWidth: 1))
    }

    private func cardHeader(_ e: TraceEvent, isOpen: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: TracePresenter.symbol(e))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent(e))
                .frame(width: 24, height: 24)
                .background(accent(e).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(TracePresenter.label(e))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tk.t1).lineLimit(1)
            Spacer(minLength: 6)
            Text(TracePresenter.shortModel(e.model))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t4).lineLimit(1)
            let meta = TracePresenter.meta(e)
            if !meta.isEmpty {
                Text(meta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t3)
            }
            Text(TracePresenter.clock(e.timestamp))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(tk.t4)
                .help(TracePresenter.stamp(e.timestamp))
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(tk.t4)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { toggle(&open, e.seq) }
    }

    @ViewBuilder private func body(_ e: TraceEvent, isOpen: Bool) -> some View {
        switch TracePresenter.kind(e) {
        case .bash: bashBody(e, isOpen: isOpen)
        case .read: readBody(e, isOpen: isOpen)
        case .edit: editBody(e, isOpen: isOpen)
        case .assistant: assistantBody(e, isOpen: isOpen)
        case .result: resultBody(e, isOpen: isOpen)
        case .generic: genericBody(e, isOpen: isOpen)
        case .usage, .thinking, .turn: EmptyView()   // rendered as thin rows, not cards
        }
    }

    // MARK: - Bash

    private func bashBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        let f = TracePresenter.bashFields(e.raw)
        return VStack(alignment: .leading, spacing: 8) {
            if let why = f.why, !why.isEmpty {
                Text(why).font(.system(size: 12.5)).foregroundStyle(tk.t1)
            }
            if isOpen {
                codeBlock(f.command, wrap: false)
            } else {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(tk.run)
                    Text(firstLine(f.command)).foregroundStyle(tk.t3).lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tk.termBg).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    // MARK: - Read

    private func readBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        let f = TracePresenter.readFields(e.raw)
        let (name, dir) = TracePresenter.splitPath(f.path)
        let range: String? = {
            guard let o = f.offset else { return nil }
            let end = o + (f.limit ?? 0) - 1
            return f.limit != nil ? "\(o)–\(end)" : "\(o)…"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(tk.t1)
                Text(dir).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t4).lineLimit(1)
                Spacer(minLength: 6)
                if let range {
                    Text(range).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.traceBlue)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(tk.traceBlue.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            if isOpen, let range {
                Text("строки \(range)").font(.system(size: 12)).foregroundStyle(tk.t3)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    // MARK: - Edit

    private func editBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        // Two sources: a Claude Edit/Write tool_use (old/new -> split diff), or a
        // Codex patch_apply fileEdit (counts only).
        let edit = TracePresenter.editFields(e.raw)
        let diff = edit.map { TracePresenter.splitDiff(old: $0.old, new: $0.new) }
        let path: String
        let addN: Int, delN: Int
        if case let .fileEdit(p, a, r, _) = e.kind {
            path = p; addN = diff?.added ?? a; delN = diff?.removed ?? r
        } else {
            path = edit?.path ?? ""; addN = diff?.added ?? 0; delN = diff?.removed ?? 0
        }
        let (name, dir) = TracePresenter.splitPath(path)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(tk.t1)
                Text(dir).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t4).lineLimit(1)
                Spacer(minLength: 6)
                countBadge("+\(addN)", tk.diffAdd)
                countBadge("−\(delN)", tk.diffDel)
            }
            if isOpen, let diff, !(diff.left.isEmpty && diff.right.isEmpty) {
                splitDiffView(diff)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    private func splitDiffView(_ d: (left: [TracePresenter.DiffLine], right: [TracePresenter.DiffLine],
                                    added: Int, removed: Int)) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                diffColumn(d.left).frame(minWidth: 170, alignment: .leading)
                tk.bd2.frame(width: 1)
                diffColumn(d.right).frame(minWidth: 170, alignment: .leading)
            }
        }
        .background(tk.termBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tk.bd2, lineWidth: 1))
    }

    private func diffColumn(_ lines: [TracePresenter.DiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, ln in
                HStack(spacing: 0) {
                    Text(ln.num.map(String.init) ?? "")
                        .frame(width: 30, alignment: .trailing).foregroundStyle(tk.t4)
                    Text(ln.kind == .del ? "−" : ln.kind == .add ? "+" : " ")
                        .frame(width: 14).foregroundStyle(ln.kind == .del ? tk.diffDel : ln.kind == .add ? tk.diffAdd : .clear)
                    Text(ln.text).foregroundStyle(tk.t1)
                        .padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced))
                .background(ln.kind == .del ? tk.diffDel.opacity(0.15)
                            : ln.kind == .add ? tk.diffAdd.opacity(0.15) : .clear)
            }
        }
    }

    // MARK: - Usage (single pinned bar → full-session history on click)

    @ViewBuilder private var usageBar: some View {
        if let u = TracePresenter.latestUsage(model.traceEvents) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10)).foregroundStyle(tk.accent)
                    Text("Usage").font(.system(size: 11, weight: .semibold)).foregroundStyle(tk.t2)
                    Text(TracePresenter.usageLine(u))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t3)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(tk.t4)
                        .rotationEffect(.degrees(usageOpen ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { usageOpen.toggle() }
                if usageOpen { usageHistoryPanel }
            }
            .background(tk.surface)
            .overlay(alignment: .bottom) { tk.bd2.frame(height: 1) }
        }
    }

    /// Scrollable history of every usage reading in the session (newest first).
    private var usageHistoryPanel: some View {
        let history = TracePresenter.usageHistory(model.traceEvents, upToSeq: .max, limit: .max)
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 10) {
                        Text(h.time).foregroundStyle(tk.t4)
                        Text("↑\(h.input)").foregroundStyle(tk.t3)
                        Text("↓\(h.output)").foregroundStyle(tk.t3)
                        Spacer()
                        Text("\(h.context) ctx").foregroundStyle(tk.t4)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .background(tk.accent.opacity(0.04))
        .overlay(alignment: .bottom) { tk.bd2.frame(height: 1) }
    }

    // MARK: - Assistant / Result / Generic

    private func assistantBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        let preview: String = { if case let .assistantText(p) = e.kind { return p }; return "" }()
        return Group {
            if isOpen {
                Text(TracePresenter.textBody(e.raw, fallback: preview))
                    .font(.system(size: 13)).foregroundStyle(tk.t1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(preview).font(.system(size: 13)).foregroundStyle(tk.t1).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    private func resultBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        let preview: String = { if case let .toolResult(_, _, p) = e.kind { return p }; return "" }()
        return VStack(alignment: .leading, spacing: 8) {
            Text(preview.isEmpty ? "—" : preview)
                .font(.system(size: 12.5)).foregroundStyle(tk.t1).lineLimit(isOpen ? nil : 2)
            if isOpen { codeBlock(TraceRow.prettyJSON(e.raw), wrap: true) }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    @ViewBuilder private func genericBody(_ e: TraceEvent, isOpen: Bool) -> some View {
        if isOpen {
            codeBlock(TraceRow.prettyJSON(e.raw), wrap: false)
                .padding(.horizontal, 14).padding(.bottom, 13)
        }
    }

    // MARK: - Thin rows (thinking / turn)

    private func thinRow(_ e: TraceEvent) -> some View {
        let isOpen = open.contains(e.seq)
        let preview: String = { if case let .thinking(p) = e.kind { return p }; return "" }()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: TracePresenter.symbol(e))
                    .font(.system(size: 10)).foregroundStyle(tk.t4)
                Text(TracePresenter.label(e))
                    .font(.system(size: 12)).italic().foregroundStyle(tk.t4)
                Spacer()
                if TracePresenter.kind(e) == .thinking {
                    Text("скрыто").font(.system(size: 10)).foregroundStyle(tk.t4)
                }
                Text(TracePresenter.clock(e.timestamp))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(tk.t4)
                    .help(TracePresenter.stamp(e.timestamp))
            }
            if isOpen, !preview.isEmpty {
                Text(preview).font(.system(size: 11.5)).foregroundStyle(tk.t3)
                    .padding(.leading, 19)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6)
        .overlay(alignment: .leading) { tk.bd2.frame(width: 2) }
        .contentShape(Rectangle())
        .onTapGesture { toggle(&open, e.seq) }
    }

    // MARK: - Source toggle

    private func sourceToggle(_ e: TraceEvent) -> some View {
        let isSrc = src.contains(e.seq)
        return VStack(spacing: 0) {
            tk.bd2.frame(height: 1)
            HStack(spacing: 7) {
                Text("{ }").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t4)
                Text("source").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tk.t4)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(tk.t4)
                    .rotationEffect(.degrees(isSrc ? 90 : 0))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { toggle(&src, e.seq) }
            if isSrc { codeBlock(TraceRow.prettyJSON(e.raw), wrap: false).padding([.horizontal, .bottom], 14) }
        }
    }

    // MARK: - Shared bits

    private func codeBlock(_ text: String, wrap: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(tk.t2)
                .textSelection(.enabled)
                .fixedSize(horizontal: wrap ? false : true, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tk.termBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tk.bd2, lineWidth: 1))
    }

    private func countBadge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(color.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
    }

    private func toggle(_ set: inout Set<Int>, _ seq: Int) {
        if set.contains(seq) { set.remove(seq) } else { set.insert(seq) }
    }
}
