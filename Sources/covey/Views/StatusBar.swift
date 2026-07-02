import SwiftUI

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(hints).foregroundStyle(.secondary).font(.caption)
            Spacer()
            if model.vimMode {
                Text(modeLabel).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            if model.historyMode {
                Text("HISTORY").foregroundStyle(.yellow).font(.caption).fontWeight(.semibold)
            }
            Text(focusLabel)
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var hints: String {
        if model.focus == .terminal { return "⌃q back to list" }
        switch model.inputMode {
        case .leader: return "esc close · backspace back"
        case .selectSession: return "1-9 jump · esc cancel"
        case .help: return "any key closes"
        case .note:
            return "space toggle · e edit · d delete · V select · y yank · esc close"
        case .normal:
            guard model.vimMode else { return "⌘N new · ⌘F filter" }
            var base = "n new · enter attach · d kill · space menu · / filter · ? help"
            if let selected = model.selected,
               !(model.promptsByName[selected] ?? []).isEmpty {
                base += " · 1-9 answer"
            }
            return base
        }
    }

    private var modeLabel: String {
        switch model.inputMode {
        case .normal: return model.focus == .terminal ? "TERM" : "NORMAL"
        case .leader: return "LEADER"
        case .selectSession: return "SELECT"
        case .help: return "HELP"
        case .note: return "NOTE"
        }
    }

    private var focusLabel: String {
        switch model.focus {
        case .sessions: return "sessions"
        case .terminal: return "terminal"
        case .inspector: return "inspector"
        }
    }
}
