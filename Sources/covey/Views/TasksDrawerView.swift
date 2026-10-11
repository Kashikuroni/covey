import SwiftUI
import CoveyKit

/// Шторка задач в режиме Sessions (spec §9.2): задачи проекта выбранной
/// сессии, быстрая привязка, компактный статус.
enum TasksDrawer {
    static func tasks(views: [PMTaskView], projectID: String?) -> [PMTaskView] {
        guard let projectID else { return [] }
        return views.filter { $0.task.projectID == projectID }
    }
}

struct TasksDrawerView: View {
    @Bindable var model: AppModel
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    /// Проект выбранной сессии: longest-prefix по демон-реестру.
    private var projectID: String? {
        guard let session = model.selectedSession() else { return nil }
        let roots = model.pm.projects.map(\.rootPath)
        guard let matched = PMAttribution.projectRoot(for: pmSessionRoot(session),
                                                      registered: roots) else { return nil }
        return model.pm.projects.first { $0.rootPath == matched }?.id
    }

    private var views: [PMTaskView] {
        TasksDrawer.tasks(views: model.pm.tasksByProject[projectID ?? ""] ?? [],
                          projectID: projectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                zoneTitle("Tasks", zone: .issues,
                          active: model.focus == .inspector, tk: tk)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, Tokens.paneHeaderTop)
            .padding(.bottom, Tokens.paneHeaderBottom)
            List {
                ForEach(TasksGrouping.group(views), id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.views) { v in
                            row(v)
                        }
                    }
                }
            }
            .listStyle(.plain)
            HStack {
                Button("New Task Here") {
                    model.pmDraft = PMDraft(projectID: projectID)
                }
                Spacer()
            }
            .padding(8)
            .background(tk.surf2)
        }
        .panelCard(tk, surface: tk.surface)
    }

    @ViewBuilder private func row(_ v: PMTaskView) -> some View {
        HStack {
            Circle().fill(v.activity == .active ? tk.run
                : v.activity == .paused ? tk.wait : tk.t3)
                .frame(width: 6, height: 6)
            Text(v.task.title).lineLimit(1).foregroundStyle(tk.t1)
            Spacer()
            if v.openBindings.isEmpty,
               v.task.lifecycle == .ready || v.task.lifecycle == .inProgress {
                Button("Bind") {
                    guard let s = model.selected else { return }
                    Task { try? await model.pm.bind(taskID: v.task.id, session: s) }
                }
                .buttonStyle(AyuButton(tk: tk, prominent: false))
            }
        }
    }
}
