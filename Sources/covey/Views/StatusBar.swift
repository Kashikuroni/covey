import SwiftUI

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("⌘N new · ⌘F filter").foregroundStyle(.secondary).font(.caption)
            Spacer()
            if model.historyMode {
                Text("HISTORY").foregroundStyle(.yellow).font(.caption).fontWeight(.semibold)
            }
            Text(focusLabel)
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var focusLabel: String {
        switch model.focus {
        case .sessions: return "sessions"
        case .terminal: return "terminal"
        case .inspector: return "inspector"
        }
    }
}
