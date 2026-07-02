import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .active

    enum Tab: String, CaseIterable { case active = "Active", recent = "Recent" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            if tab == .active { activeList } else { recentList }
        }
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
    }

    private var dirs: [String] {
        var seen = Set<String>()
        return model.sessions.map(\.dir).filter { seen.insert($0).inserted }
    }

    private var activeList: some View {
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
    }

    // Recent, newest-first, hiding any name that is currently Active.
    private var recentList: some View {
        let active = Set(model.sessions.map(\.name))
        let items = model.recents.filter { !active.contains($0.name) }
        return List {
            ForEach(items, id: \.name) { r in
                HStack(spacing: 6) {
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name)
                        Text(r.dir).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Relaunch") { Task { await model.relaunchRecent(r) } }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selected },
                set: { name in Task { await model.select(name) } })
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(model.statusByName[session.name] ?? .idle))
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
