import SwiftUI
import CoveyKit

struct TerminalPaneView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.selected,
               let session = model.sessions.first(where: { $0.name == name }) {
                header(session)
                Divider()
                TerminalRepresentable(model: model)
                    .id(name)   // fresh TerminalView per session (spec §5)
            } else {
                Spacer()
                Text("no session selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func header(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Text(session.name).fontWeight(.semibold)
            Text(session.dir).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(session.agent).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
