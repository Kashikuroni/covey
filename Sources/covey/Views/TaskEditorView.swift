import SwiftUI
import CoveyKit

/// Черновик быстрого создания задачи (модалка из режима Projects / шторки).
struct PMDraft: Equatable, Identifiable {
    var id = UUID()
    var projectID: String?
    var title = ""
    var body = ""
    var idleThresholdText = PMIdleThreshold.format(PMIdleThreshold.defaultSeconds)
}

/// Чистая модель редактора: черновик тела, dirty, debounce-сохранение.
/// Save-замыкание возвращает новую ревизию — она становится рабочей:
/// каждый следующий autosave идёт с ней, а не с протухшей (finding 2).
@MainActor @Observable
final class TaskEditorModel {
    var body: String
    var idleThresholdText: String
    private(set) var lastError: String?
    private var original: String
    private var originalThresholdText: String
    private var revision: Int64
    private let save: (String, Int?, Int64) async throws -> Int64
    private var saveTask: Task<Void, Never>?

    var isDirty: Bool { body != original || idleThresholdText != originalThresholdText }

    init(task: PMTask,
         save: @escaping (String, Int?, Int64) async throws -> Int64) {
        self.body = task.body
        self.original = task.body
        let threshold = PMIdleThreshold.format(
            task.idleThresholdSeconds ?? PMIdleThreshold.defaultSeconds)
        self.idleThresholdText = threshold
        self.originalThresholdText = threshold
        self.revision = task.revision
        self.save = save
    }

    /// Debounce 1s; saveNow — немедленно (кнопка Save).
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.performSave()
        }
    }

    func saveNow() async throws {
        saveTask?.cancel()
        _ = try await performSave()
    }

    @discardableResult
    private func performSave() async throws -> Int64 {
        let threshold = PMIdleThreshold.parse(idleThresholdText)
        do {
            let newRevision = try await save(body, threshold, revision)
            revision = newRevision
            lastError = nil
            // Успешное сохранение = сохранённое стало эталоном для dirty.
            original = body
            originalThresholdText = threshold.map { PMIdleThreshold.format($0) } ?? idleThresholdText
            return newRevision
        } catch {
            lastError = "save failed: \(error.localizedDescription.isEmpty ? "\(error)" : error.localizedDescription)"
            throw error
        }
    }
}

/// Редактор задачи: заголовок и статус, действия, VimEditor (правка+превью),
/// порог простоя. Сохранение — tasks.update через демон.
struct TaskEditorView: View {
    let model: AppModel
    let taskView: PMTaskView
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    @State private var editor: TaskEditorModel?
    @State private var vimBadge: String?
    @State private var focusTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            actions
            HStack {
                Text("pause after").font(.caption).foregroundStyle(tk.t3)
                TextField("15m", text: binding(\.idleThresholdText))
                    .frame(width: 60)
                    .ayuField(tk)
                Text("idle").font(.caption).foregroundStyle(tk.t3)
            }
            if let editor {
                VimEditor(text: Binding(get: { editor.body },
                                        set: { editor.body = $0; editor.scheduleSave() }),
                          modeBadge: Binding(get: { vimBadge ?? "" },
                                             set: { vimBadge = $0.isEmpty ? nil : $0 }),
                          tk: tk,
                          focusTick: focusTick,
                          onSwitchField: { _ in })
            }
            if let e = editor, e.isDirty {
                HStack {
                    Button("Save Now") { Task { try? await e.saveNow() } }
                        .buttonStyle(AyuButton(tk: tk, prominent: true))
                    if let err = e.lastError {
                        Text(err).font(.caption).foregroundStyle(tk.err).lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
        .padding(8)
        .task(id: taskView.task.id) {
            editor = makeEditor()
        }
    }

    private func makeEditor() -> TaskEditorModel {
        let task = taskView.task
        let pm = model.pm
        return TaskEditorModel(task: task) { body, threshold, expectedRevision in
            let updated = try await pm.updateTask(id: task.id, projectID: task.projectID,
                                                  title: nil, body: body,
                                                  idleThresholdS: threshold,
                                                  expectedRevision: expectedRevision)
            return updated.revision
        }
    }

    private var header: some View {
        HStack {
            Text(taskView.task.title).font(.title3).foregroundStyle(tk.t1)
            Text(taskView.task.lifecycle.rawValue)
                .font(.caption).padding(3)
                .background(tk.surf4).clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
            Text(taskView.activity.rawValue)
                .font(.caption).padding(3)
                .background(tk.surf4).clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
            Spacer()
        }
    }

    private var actions: some View {
        HStack {
            Button("Spawn Session") {
                Task { try? await model.pm.spawn(taskID: taskView.task.id) }
            }
            .buttonStyle(AyuButton(tk: tk, prominent: true))
            .disabled(taskView.task.lifecycle != .ready && taskView.task.lifecycle != .inProgress)
            Button("Bind Selected") {
                if let s = model.selected {
                    Task { try? await model.pm.bind(taskID: taskView.task.id, session: s) }
                }
            }
            .disabled(model.selected == nil)
            Spacer()
            Button("Done") {
                Task { try? await model.pm.setLifecycle(task: taskView.task, to: .done) }
            }
            .disabled(taskView.task.lifecycle == .done || taskView.task.lifecycle == .archived)
            Button("Failed") {
                Task { try? await model.pm.setLifecycle(task: taskView.task, to: .failed) }
            }
            .disabled(taskView.task.lifecycle == .failed || taskView.task.lifecycle == .archived)
            if taskView.task.lifecycle == .done || taskView.task.lifecycle == .failed
                || taskView.task.lifecycle == .cancelled {
                Button("Reopen") {
                    Task { try? await model.pm.setLifecycle(task: taskView.task, to: .inProgress) }
                }
            }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<TaskEditorModel, String>) -> Binding<String> {
        Binding(get: { editor?[keyPath: keyPath] ?? "" },
                set: { editor?[keyPath: keyPath] = $0; editor?.scheduleSave() })
    }
}

/// Модалка создания задачи (pmDraft).
struct PMDraftSheet: View {
    let model: AppModel
    let draft: PMDraft
    @State private var title = ""
    @State private var body_ = ""
    @State private var thresholdText = PMIdleThreshold.format(PMIdleThreshold.defaultSeconds)
    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Task").font(.headline).foregroundStyle(tk.t1)
            TextField("Title", text: $title)
                .ayuField(tk)
            TextEditor(text: $body_)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 140)
                .scrollContentBackground(.hidden)
                .background(tk.surf2)
            HStack {
                Text("pause after").font(.caption).foregroundStyle(tk.t3)
                TextField("15m", text: $thresholdText)
                    .frame(width: 60)
                    .ayuField(tk)
                Spacer()
                Button("Cancel") { model.pmDraft = nil }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                Button("Create") { create() }
                    .buttonStyle(AyuButton(tk: tk, prominent: true))
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.projectID == nil)
            }
        }
        .padding(12)
        .frame(width: 460)
        .onAppear {
            title = draft.title
            body_ = draft.body
            thresholdText = draft.idleThresholdText
        }
    }

    private func create() {
        guard let pid = draft.projectID else { return }
        let t = title, b = body_
        let threshold = PMIdleThreshold.parse(thresholdText)
        model.pmDraft = nil
        Task {
            try? await model.pm.createTask(projectID: pid, title: t, body: b,
                                           idleThresholdS: threshold)
        }
    }
}
