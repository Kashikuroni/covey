import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel

    private var dirs: [String] {
        var seen = Set<String>()
        return model.sessions.map(\.dir).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(dirs, id: \.self) { dir in
                Section(dir) {
                    ForEach(model.sessions.filter { $0.dir == dir }, id: \.name) { session in
                        row(session)
                            .tag(session.name)
                            .contextMenu {
                                Button("Rename…") { model.modal = .rename(session.name) }
                                Button("Kill…", role: .destructive) { model.modal = .kill(session.name) }
                            }
                    }
                }
            }
        }
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selected },
            set: { name in Task { await model.select(name) } }
        )
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(model.statusByName[session.name] ?? .idle))
                .frame(width: 8, height: 8)
            Text(session.name)
            Spacer()
            Text(session.agent).foregroundStyle(.secondary).font(.caption)
        }
    }

    private func statusColor(_ status: Status) -> Color {
        switch status {
        case .running: return .orange
        case .waiting: return .yellow
        case .idle: return .gray
        }
    }
}
