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
            Text(model.focus == .sessions ? "sessions" : "terminal")
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
