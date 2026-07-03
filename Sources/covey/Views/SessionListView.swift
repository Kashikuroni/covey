import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { model.listTab },
                set: { model.setListTab($0) })) {
                Text("Active").tag(AppModel.ListTab.active)
                Text("Recent").tag(AppModel.ListTab.recent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            if model.listTab == .active {
                TextField("Filter", text: Binding(
                    get: { model.filter }, set: { model.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .padding(.horizontal, 6)
                    .onChange(of: model.filterFocusTick) { _, _ in filterFocused = true }
                    .onExitCommand {
                        model.setFilter("")
                        filterFocused = false
                    }
            }
            if model.listTab == .active { activeList } else { recentList }
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
                    Section {
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
                    } header: {
                        HStack(spacing: 6) {
                            Text(model.displayName(forDir: group.dir))
                            let pc = taskCounts(model.projectNotes[group.dir] ?? "")
                            if pc.total > 0 {
                                Text("\(pc.done)/\(pc.total)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // Recent, newest-first, hiding any name that is currently Active.
    private var recentList: some View {
        let items = model.visibleRecents()
        return List {
            ForEach(Array(items.enumerated()), id: \.element.name) { idx, r in
                HStack(spacing: 6) {
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(r.name)
                            if r.resumeCmd != nil {
                                // Relaunch continues the saved conversation.
                                Text("↻").foregroundStyle(.secondary).font(.caption)
                                    .help("relaunch resumes the conversation")
                            }
                            Spacer()
                            Text(String(r.agent.split(separator: " ").first ?? ""))
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        Text(collapseHome(r.dir))
                            .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                            .truncationMode(.head)
                    }
                    Button("Relaunch") { Task { await model.relaunchRecent(r) } }
                        .buttonStyle(.borderless)
                }
                .listRowBackground(model.recentSelected == idx
                                   ? Color.accentColor.opacity(0.15) : nil)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selected },
                set: { name in Task { await model.select(name) } })
    }

    private func row(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor(model.statusByName[session.name] ?? .idle))
                    .frame(width: 8, height: 8)
                Text(session.name)
                let counts = taskCounts(model.notes[session.name] ?? "")
                if counts.total > 0 {
                    Text("\(counts.done)/\(counts.total)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.agent).foregroundStyle(.secondary).font(.caption)
            }
            if let git = session.git {
                HStack(spacing: 4) {
                    Text(session.worktreeRepo != nil ? "⧉" : "⎇")
                    Text(git.branch).lineLimit(1)
                    if git.added > 0 { Text("+\(git.added)").foregroundStyle(.green) }
                    if git.removed > 0 { Text("−\(git.removed)").foregroundStyle(.red) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if let options = model.promptsByName[session.name], !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(options.prefix(9).enumerated()), id: \.offset) { idx, label in
                        Button("\(idx + 1) \(label)") {
                            Task { await model.select(session.name) }
                            model.answerPrompt(idx + 1, session: session.name)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .lineLimit(1)
                    }
                }
            }
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
