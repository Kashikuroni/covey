import SwiftUI
import AppKit
import CoveyKit

/// GitHub-issue composer living in the inspector: per-project draft,
/// ⌘-chords with footer hints, async gh stages. `gh issue create --web`
/// pre-fills the browser form from the same fields.
struct IssuePane: View {
    @Bindable var model: AppModel

    enum Stage: Equatable {
        case editing, creating
        case done(String)
        case failed(String)
    }

    @State private var stage: Stage = .editing
    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var root: String? { model.inspectorRoot }
    private var dir: String? { model.inspectorDir }

    private var draft: IssueDraft {
        root.map { model.issueDraft(forRoot: $0) } ?? IssueDraft()
    }

    private func update(_ transform: (inout IssueDraft) -> Void) {
        guard let root else { return }
        var d = model.issueDraft(forRoot: root)
        transform(&d)
        model.setIssueDraft(d, forRoot: root)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if root == nil {
                Text("no project — Command-P › Add Project")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch stage {
                case .editing: editor
                case .creating:
                    statusCard(tk: tk, tint: tk.wait, title: "creating issue…", spinner: true) {
                        Text("esc hide — gh keeps running")
                            .font(.caption2).foregroundStyle(tk.t4)
                    }
                    Spacer()
                case .done(let url):
                    statusCard(tk: tk, icon: "checkmark", tint: tk.ok, title: "issue created") {
                        Text(url).font(.caption.monospaced()).foregroundStyle(tk.t2)
                            .textSelection(.enabled).lineLimit(2)
                        Text("URL copied to clipboard")
                            .font(.caption2).foregroundStyle(tk.t4)
                    }
                    Button("New issue") { stage = .editing }
                        .buttonStyle(AyuButton(tk: tk, prominent: false))
                    Spacer()
                case .failed(let err):
                    statusCard(tk: tk, icon: "xmark", tint: tk.err, title: "issue not created") {
                        // Raw gh stderr — mono and dimmed, the card border
                        // carries the severity instead of a wall of red.
                        Text(err).font(.caption.monospaced()).foregroundStyle(tk.t2)
                            .textSelection(.enabled).lineLimit(8)
                    }
                    Button("Back") { stage = .editing }
                        .buttonStyle(AyuButton(tk: tk, prominent: false))
                    Spacer()
                }
            }
        }
        .padding(8)
        .onChange(of: model.issueFocusTick) { _, _ in
            stage = .editing
            titleFocused = true
        }
        .onChange(of: titleFocused) { _, focused in
            syncEditing()
            if focused { placeTitleCaretAtEnd() }
        }
        .onChange(of: bodyFocused) { _, _ in syncEditing() }
        .task(id: root) { await model.issueBrowser.loadLabelsIfNeeded(dir: dir) }
    }

    /// On focus macOS selects the whole title; drop the caret at the end so a
    /// stray keystroke can't wipe it (the title carries the system task id).
    private func placeTitleCaretAtEnd() {
        DispatchQueue.main.async {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            }
        }
    }

    private func syncEditing() {
        // The body's badge is the vim editor's business; INSERT here only
        // reflects the plain title field.
        model.inspectorEditing = titleFocused
    }

    private var editor: some View {
        Group {
            Text("in: \(collapseHome(root ?? ""))")
                .font(.caption.monospaced()).foregroundStyle(tk.t3).lineLimit(1)
            TextField("Title", text: Binding(
                get: { draft.title },
                set: { v in update { $0.title = v } }))
                .focused($titleFocused)
                .ayuField(tk, focused: titleFocused)
                .onSubmit { submit() }
            VimEditor(text: Binding(
                get: { draft.body },
                set: { v in update { $0.body = v } }),
                      modeBadge: Binding(
                get: { model.inspectorVimBadge ?? "" },
                set: { model.inspectorVimBadge = $0.isEmpty ? nil : $0 }),
                      tk: tk,
                      onSwitchField: { _ in
                bodyFocused = false
                titleFocused = true
            })
            .focused($bodyFocused)
            .frame(height: 140)
            HStack(spacing: 8) {
                Image(systemName: draft.assignMe ? "checkmark.square.fill" : "square")
                    .foregroundStyle(draft.assignMe ? Color.accentColor : .secondary)
                Text("Assign to me").font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { update { $0.assignMe.toggle() } }
            LabelSelector(tk: tk,
                          labels: model.issueBrowser.labels ?? [],
                          loading: model.issueBrowser.labelsLoading,
                          picked: Binding(get: { Set(draft.labels) },
                                          set: { s in update { $0.labels = s.sorted() } }))
            HStack {
                Spacer()
                Button("Open in browser…") { submit(web: true) }
                    .buttonStyle(AyuButton(tk: tk, prominent: false))
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Create") { submit() }
                    .buttonStyle(AyuButton(tk: tk, prominent: true))
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // ⌘M rides a hidden button: the visible checkbox is not a Button.
            Button("") { update { $0.assignMe.toggle() } }
                .keyboardShortcut("m", modifiers: .command)
                .hidden().frame(width: 0, height: 0)
            Spacer(minLength: 0)
        }
    }

    private func submit(web: Bool = false) {
        guard let root, let dir else { return }
        let d = model.issueDraft(forRoot: root)
        let title = d.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        stage = .creating
        Task { @MainActor in
            switch await IssueService.create(dir: dir, title: title, body: d.body,
                                             assignMe: d.assignMe, labels: d.labels,
                                             web: web) {
            case .success(let url):
                if web {
                    stage = .editing   // draft stays; the browser owns it now
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                model.clearIssueDraft(forRoot: root)
                model.issueBrowser.invalidate(root: root)
                stage = .done(url)
                model.showToast("issue created — URL copied")
            case .failure(let err):
                stage = .failed(err)
            }
        }
    }
}
