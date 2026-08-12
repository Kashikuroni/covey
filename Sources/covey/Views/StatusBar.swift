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
        // The workspace no longer pads this side, so the footer's own inset is
        // the whole gap under the cards — symmetric, which centres the hints in
        // the strip between the last card and the window's bottom edge.
        .padding(.horizontal, 12).padding(.vertical, 8)
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
                KbdBadge(key: key, label: label, tk: tk)
            }
        }
    }

    private var hintPairs: [(String, String)] {
        if model.focus == .terminal { return [("⌃q", "back to list")] }
        if model.focus == .inspector {
            // App-level hints only; the editor's own footer carries the
            // per-mode vim hints. While typing, most app keys are dead —
            // do not lie about them.
            if model.inspectorVimBadge == "INSERT" || model.inspectorEditing {
                return [("esc", "leave insert")]
            }
            if model.inspectorMode == .issues {
                if model.issueScreen == .composer {
                    return [("⌘ M", "assign"), ("⌘ O", "browser"), ("enter", "create"),
                            ("esc", "issues"), ("⌃h/⌃l", "zones")]
                }
                switch model.issueBrowser.screen {
                case .list:
                    return [("enter", "view"), ("s", "session"), ("n", "new"),
                            ("o", "state"), ("/", "search"), ("e/c/x", "edit/close/del")]
                case .detail:
                    return [("e", "edit"), ("s", "session"), ("g", "session ↗"),
                            ("c", "close/reopen"), ("x", "delete"), ("b", "browser"),
                            ("esc", "list")]
                case .edit:
                    return [("enter", "save"), ("esc", "cancel")]
                }
            }
            return [("space", "menu"), ("⌃h/⌃l", "zones")]
        }
        switch model.inputMode {
        case .leader: return [("esc", "close"), ("⌫", "back")]
        case .selectSession: return [("1-9", "jump"), ("esc", "cancel")]
        case .help: return [("any key", "closes")]
        case .limits: return [("any key", "closes")]
        case .normal:
            guard model.vimMode else { return [("⌘N", "new"), ("⌘F", "filter")] }
            return [
                ("n", "new"), ("r", "recent"), ("enter", "attach"), ("d", "kill"),
                ("space", "menu"), ("/", "filter"), ("?", "help"),
            ]
        }
    }

}
