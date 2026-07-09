import SwiftUI
import CoveyKit

struct SessionListView: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    /// mono helper matching the amux type scale
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Zone tab matching the terminal panes' Agent/Terminal headers.
            HStack {
                zoneTitle("Session", badge: 1,
                          active: model.focus == .sessions, tk: tk)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tk.surface)
            .contentShape(Rectangle())
            .onTapGesture { model.setFocus(.sessions) }
            activeList
        }
    }

    private var activeList: some View {
        let groups = model.orderedSessions()
        let filtering = !model.filter.isEmpty
        // No List(selection:): the system paints its own (blue) selection
        // under the card — the card renders selection itself, clicks select.
        return List {
            ForEach(groups, id: \.dir) { group in
                let rows = group.sessions.filter { fuzzyMatch(model.filter, $0.name) }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.name) { session in
                            card(session)
                                .onTapGesture { Task { await model.select(session.name) } }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                // The List's private table pads rows by a
                                // fixed 8pt per side that no SwiftUI
                                // modifier removes (probed on macOS 26).
                                // Make 8pt the uniform gap instead:
                                // horizontal 0 (table's own 8), vertical
                                // 4 + 4 between cards.
                                .listRowInsets(EdgeInsets(top: 4, leading: 0,
                                                          bottom: 4, trailing: 0))
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
                        projectHeader(group: group, rows: rows)
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)
                } else if group.sessions.isEmpty, !filtering {
                    Section {
                        ghostRow(dir: group.dir)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0,
                                                      bottom: 4, trailing: 0))
                    } header: {
                        projectHeader(group: group, rows: [])
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tk.surface)
    }

    private func projectHeader(group: (dir: String, sessions: [Session]),
                               rows: [Session]) -> some View {
        let running = rows.filter { model.statusByName[$0.name] == .running }.count
        return HStack(spacing: 6) {
            Text(model.displayName(forDir: group.dir).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(tk.t4)
            let pc = taskCounts(model.projectNotes[group.dir] ?? "")
            if pc.total > 0 {
                Text("\(pc.done)/\(pc.total)").font(mono(10)).foregroundStyle(tk.t4)
            }
            Spacer()
            Text("\(running)/\(rows.count)").font(mono(11)).foregroundStyle(tk.t4)
        }
    }

    /// Empty registered project: a selectable stub row in place of cards.
    private func ghostRow(dir: String) -> some View {
        let selected = model.selectedProjectRoot == dir && model.selected == nil
        return HStack {
            Text("no sessions — N to start")
                .font(mono(11)).foregroundStyle(tk.t4)
            Spacer()
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(selected ? tk.bd3 : tk.bd,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.selectProject(dir) } }
        .contextMenu {
            Button("Remove project") { model.removeProject(dir) }
        }
    }

    private func card(_ session: Session) -> some View {
        let selected = model.selected == session.name
        let status = model.statusByName[session.name] ?? .idle
        let modelName = model.modelByName[session.name].map(modelDisplayName)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.name)
                    .font(mono(13, .medium))
                    .foregroundStyle(selected ? tk.t1 : (status == .waiting ? tk.wait : tk.t2))
                    .lineLimit(1)
                let counts = taskCounts(model.notes[session.name] ?? "")
                if counts.total > 0 {
                    Text("\(counts.done)/\(counts.total)")
                        .font(mono(10)).foregroundStyle(tk.t4)
                }
                Spacer()
                Text(sessionStatusLabel(status))
                    .font(mono(11)).foregroundStyle(sessionStatusTint(status, tk: tk))
                AgentIcon(agent: session.agent, tk: tk)
            }
            Group {
                if isReturnable(session) {
                    Text("⧉ worktree removed — space g r returns to root")
                        .font(mono(11)).foregroundStyle(tk.t4)
                } else if session.git != nil || modelName != nil {
                    HStack(spacing: 6) {
                        if let modelName {
                            Text(modelName).font(mono(9)).foregroundStyle(tk.t4)
                        }
                        if let git = session.git {
                            HStack(spacing: 3) {
                                Text(session.worktreeRepo != nil ? "⧉" : "⎇")
                                    .font(.system(size: 10)).foregroundStyle(tk.t4)
                                Text(git.branch).font(mono(9)).foregroundStyle(tk.t3)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if let git = session.git, git.added > 0 || git.removed > 0 {
                            HStack(spacing: 4) {
                                if git.added > 0 {
                                    Text("+\(git.added)")
                                        .foregroundStyle(tk.diffAdd.opacity(0.65))
                                }
                                if git.removed > 0 {
                                    Text("−\(git.removed)")
                                        .foregroundStyle(tk.diffDel.opacity(0.65))
                                }
                            }
                            .font(mono(11))
                        }
                    }
                }
            }
            if let options = model.promptsByName[session.name], !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(options.prefix(9).enumerated()), id: \.offset) { idx, label in
                        Button("\(idx + 1) \(label)") {
                            Task { await model.select(session.name) }
                            model.answerPrompt(idx + 1, session: session.name)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                        .lineLimit(1)
                    }
                }
                }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(selected ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            // The amux status stripe: selection wins, then waiting.
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? tk.t1 : (status == .waiting ? tk.wait : .clear))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .shadow(color: tk.shadowColor, radius: Tokens.shadowRadius, y: Tokens.shadowY)
    }

}
