import SwiftUI

struct StatusBar: View {
    let model: AppModel
    @FocusState private var filterFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        HStack(spacing: 12) {
            if model.filterActive {
                filterRow
            } else {
                hintsRow
            }
            Spacer()
            if model.historyMode {
                Text("HISTORY").foregroundStyle(.yellow).font(.caption).fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(tk.surface)
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            Text("/").font(.caption.monospaced()).foregroundStyle(tk.accent)
            TextField("filter", text: Binding(
                get: { model.filter }, set: { model.setFilter($0) }))
                .ayuField(tk, focused: filterFocused)
                .frame(width: 180)
                .focused($filterFocused)
                .onAppear { filterFocused = true }
                .onExitCommand { model.filterEscape() }
                .onSubmit { model.filterCommit() }
                .onKeyPress(.downArrow) { model.apply(.selectNext); return .handled }
                .onKeyPress(.upArrow) { model.apply(.selectPrev); return .handled }
                .onKeyPress(phases: .down) { press in
                    // ⌃j/⌃k walk the filtered list; plain letters type into
                    // the field (so names containing j/k stay findable).
                    guard press.modifiers.contains(.control) else { return .ignored }
                    switch press.key {
                    case "j": model.apply(.selectNext); return .handled
                    case "k": model.apply(.selectPrev); return .handled
                    default: return .ignored
                    }
                }
            Text("\(model.visibleSessionNames().count)/\(model.visibleSessions.count)")
                .font(.caption.monospaced()).foregroundStyle(tk.t4)
        }
    }

    /// amux statusbar style: bright kbd badge + dim label per hint.
    private var hintsRow: some View {
        HStack(spacing: 10) {
            ForEach(hintPairs, id: \.0) { key, label in
                HStack(spacing: 4) {
                    kbd(key)
                    Text(label).font(.caption).foregroundStyle(tk.t4)
                }
            }
        }
    }

    private func kbd(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tk.t2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tk.surf2, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tk.bd2))
    }

    private var hintPairs: [(String, String)] {
        if model.focus == .terminal { return [("⌃q", "back to list")] }
        switch model.inputMode {
        case .leader: return [("esc", "close"), ("⌫", "back")]
        case .selectSession: return [("1-9", "jump"), ("esc", "cancel")]
        case .help: return [("any key", "closes")]
        case .note:
            return [("space", "toggle"), ("e", "edit"), ("d", "delete"),
                    ("V", "select"), ("y", "yank"), ("esc", "close")]
        case .normal:
            guard model.vimMode else { return [("⌘N", "new"), ("⌘F", "filter")] }
            var base: [(String, String)] = [
                ("n", "new"), ("r", "recent"), ("enter", "attach"), ("d", "kill"),
                ("space", "menu"), ("/", "filter"), ("?", "help"),
            ]
            if let selected = model.selected,
               !(model.promptsByName[selected] ?? []).isEmpty {
                base.append(("1-9", "answer"))
            }
            return base
        }
    }

}
