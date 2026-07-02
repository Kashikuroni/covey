import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .active
    @FocusState private var filterFocused: Bool

    enum Tab: String, CaseIterable { case active = "Active", recent = "Recent" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            if tab == .active {
                TextField("Filter", text: Binding(
                    get: { model.filter }, set: { model.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .padding(.horizontal, 6)
                    .onChange(of: model.filterFocusTick) { _, _ in filterFocused = true }
            }
            if tab == .active { activeList } else { recentList }
        }
        .toolbar {
            Button { model.modal = .newSession } label: { Image(systemName: "plus") }
                .help("New session")
        }
    }

    private var activeList: some View {
        let groups = model.orderedSessions()
        let filtering = !model.filter.isEmpty
        return List(selection: selectionBinding) {
            ForEach(groups, id: \.dir) { group in
                let rows = group.sessions.filter { fuzzyMatch(model.filter, $0.name) }
                if !rows.isEmpty {
                    Section(group.dir) {
                        ForEach(rows, id: \.name) { session in
                            row(session)
                                .tag(session.name)
                                .contextMenu {
                                    Button("Rename…") { model.modal = .rename(session.name) }
                                    Button("Kill…", role: .destructive) { model.modal = .kill(session.name) }
                                }
                        }
                        .onMove { from, to in
                            guard !filtering else { return }
                            model.moveSession(inDir: group.dir, from: from, to: to)
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
