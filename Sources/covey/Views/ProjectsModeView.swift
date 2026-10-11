import SwiftUI
import CoveyKit

/// Группировка списка задач: In Progress (active раньше paused), Ready, Closed.
enum TasksGrouping {
    static func group(_ views: [PMTaskView]) -> [(label: String, views: [PMTaskView])] {
        let inProgress = views
            .filter { $0.task.lifecycle == .inProgress }
            .sorted { a, b in
                if (a.activity == .active) != (b.activity == .active) {
                    return a.activity == .active
                }
                return a.task.updatedAt > b.task.updatedAt
            }
        let ready = views.filter { $0.task.lifecycle == .ready }
            .sorted { $0.task.updatedAt > $1.task.updatedAt }
        let closed = views.filter {
            [.done, .failed, .cancelled, .archived].contains($0.task.lifecycle)
        }.sorted { ($0.task.closedAt ?? 0) > ($1.task.closedAt ?? 0) }
        return [("In Progress", inProgress), ("Ready", ready), ("Closed", closed)]
            .filter { !$0.views.isEmpty }
    }
}

/// Режим главного окна Projects: проекты | задачи | детали (spec §9.1).
/// Лежит поверх sessions-workspace как Review/Forecast — терминалы не
/// ресайзятся и не получают SIGWINCH. Редактор задачи и аналитика приезжают
/// следующими слайсами (TaskEditorView / PMAnalyticsView).
struct ProjectsModeView: View {
    let model: AppModel
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    @State private var selectedProjectID: String?
    @State private var selectedTaskID: String?

    var body: some View {
        HStack(spacing: 0) {
            projectColumn
                .frame(width: 220)
            Divider().overlay(tk.bd3)
            taskColumn
                .frame(maxWidth: .infinity)
            Divider().overlay(tk.bd3)
            detailColumn
                .frame(width: 460)
        }
        .background(tk.surf3)
        .onAppear {
            if selectedProjectID == nil { selectedProjectID = model.pm.projects.first?.id }
        }
    }

    private var projectColumn: some View {
        List(selection: $selectedProjectID) {
            ForEach(model.pm.projects.filter { $0.archivedAt == nil }) { p in
                HStack {
                    Text(p.name).foregroundStyle(tk.t1)
                    if p.missing == true {
                        Text("missing").font(.caption2).foregroundStyle(tk.warn)
                    }
                }
                .tag(p.id)
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            Button("Add Project") { model.addProjectPrompt() }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(tk.surf2)
        }
    }

    private var tasks: [PMTaskView] {
        guard let id = selectedProjectID else { return [] }
        return model.pm.tasksByProject[id] ?? []
    }

    private var taskColumn: some View {
        List(selection: $selectedTaskID) {
            ForEach(TasksGrouping.group(tasks), id: \.label) { group in
                Section(group.label) {
                    ForEach(group.views) { v in
                        TaskRow(view: v, tk: tk)
                            .tag(v.task.id)
                    }
                }
            }
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let v = tasks.first(where: { $0.task.id == selectedTaskID }) {
            TaskSummaryView(view: v, tk: tk)
        } else {
            Text("Select a task").foregroundStyle(tk.t3)
        }
    }
}

/// Read-only сводка задачи до приезда редактора (следующий слайс).
struct TaskSummaryView: View {
    let view: PMTaskView
    let tk: Tokens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(view.task.title).font(.title3).foregroundStyle(tk.t1)
                HStack(spacing: 8) {
                    Text(view.task.lifecycle.rawValue)
                        .font(.caption).padding(3)
                        .background(tk.surf4).clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                    Text(view.activity.rawValue)
                        .font(.caption).padding(3)
                        .background(tk.surf4).clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                    Text(view.task.assignee).font(.caption).foregroundStyle(tk.t3)
                }
                if !view.openBindings.isEmpty {
                    Text("Sessions: " + view.openBindings.map(\.coveySession).joined(separator: ", "))
                        .font(.caption).foregroundStyle(tk.t2)
                }
                if !view.task.body.isEmpty {
                    Text(view.task.body).font(.body).foregroundStyle(tk.t2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

struct TaskRow: View {
    let view: PMTaskView
    let tk: Tokens

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(view.activity == .active ? tk.run
                    : view.activity == .paused ? tk.wait : tk.t3)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(view.task.title).lineLimit(1).foregroundStyle(tk.t1)
                if !view.openBindings.isEmpty {
                    Text(view.openBindings.map(\.coveySession).joined(separator: ", "))
                        .font(.caption).foregroundStyle(tk.t3).lineLimit(1)
                }
            }
            Spacer()
            Text(view.task.lifecycle.rawValue)
                .font(.caption2).foregroundStyle(tk.t3)
        }
        .padding(.vertical, 2)
    }
}
