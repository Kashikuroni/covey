import SwiftUI

/// Issue editor: title, body (vim), label checklist. Sends only the diff
/// (changed title/body, added/removed labels) via browser.saveEdit.
struct IssueEditView: View {
    @Bindable var model: AppModel
    let issue: GhIssue

    @State private var title: String
    @State private var body_: String
    @State private var picked: Set<String>
    @State private var saving = false
    @State private var editorFocusTick = 0
    @FocusState private var titleFocused: Bool
    @FocusState private var focusedLabel: String?

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var browser: IssueBrowserModel { model.issueBrowser }

    init(model: AppModel, issue: GhIssue) {
        self.model = model
        self.issue = issue
        _title = State(initialValue: issue.title)
        _body_ = State(initialValue: issue.body)
        _picked = State(initialValue: Set(issue.labels.map(\.name)))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                Text("edit #\(issue.number)")
                    .font(.system(size: IssueFont.meta, design: .monospaced)).foregroundStyle(tk.t3)
                TextField("Title", text: $title)
                    .focused($titleFocused)
                    .ayuField(tk, focused: titleFocused)
                    .onSubmit { save() }
                VimEditor(text: $body_, modeBadge: Binding(
                    get: { model.inspectorVimBadge ?? "" },
                    set: { model.inspectorVimBadge = $0.isEmpty ? nil : $0 }),
                          tk: tk,
                          focusTick: editorFocusTick,
                          onSwitchField: { forward in switchFromBody(forward: forward) })
                    .frame(height: max(120, geo.size.height * 0.5))
                labelChecklist
                HStack {
                    Spacer()
                    Button("Cancel") { browser.screen = .detail(issue.number) }
                        .buttonStyle(AyuButton(tk: tk, prominent: false))
                    Button("Save") { save() }
                        .buttonStyle(AyuButton(tk: tk, prominent: true))
                        .disabled(saving ||
                                  title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .onExitCommand { browser.screen = .detail(issue.number) }
        .task { await browser.loadLabelsIfNeeded() }
        .onAppear { titleFocused = true }
    }

    /// Tab out of the body editor: forward lands on the first label (the
    /// form order title → body → labels), backward returns to the title.
    private func switchFromBody(forward: Bool) {
        if forward, let first = browser.labels?.first?.name {
            focusedLabel = first
        } else {
            titleFocused = true
        }
    }

    @ViewBuilder
    private var labelChecklist: some View {
        if browser.labelsLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("loading labels…").font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
            }
        } else if let labels = browser.labels, !labels.isEmpty {
            let names = labels.map(\.name)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(labels, id: \.name) { label in
                        labelRow(label.name, allNames: names)
                    }
                }
            }
            .frame(maxHeight: 90)
        }
    }

    /// Keyboard-first checklist row (idiom: NewSessionSheet's toggleRow).
    /// Space/←/→ toggle the focused row; j/k and ↓/↑ move focus between rows.
    private func labelRow(_ name: String, allNames: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: picked.contains(name) ? "checkmark.square.fill" : "square")
                .foregroundStyle(picked.contains(name) ? Color.accentColor : .secondary)
            Text(name).font(.system(size: IssueFont.body))
            Spacer()
        }
        .contentShape(Rectangle())
        .background(focusedLabel == name ? Color.accentColor.opacity(0.12) : .clear)
        .focusable()
        .focused($focusedLabel, equals: name)
        .onKeyPress(phases: .down) { press in handleLabelKey(press, name: name, allNames: allNames) }
        .onTapGesture {
            toggleLabel(name)
            focusedLabel = name
        }
    }

    private func handleLabelKey(_ press: KeyPress, name: String, allNames: [String]) -> KeyPress.Result {
        switch press.key {
        case .space, .leftArrow, .rightArrow:
            toggleLabel(name)
            return .handled
        case .downArrow:
            moveLabelFocus(1, in: allNames)
            return .handled
        case .upArrow:
            moveLabelFocus(-1, in: allNames)
            return .handled
        case .tab:
            // Keep the form cycle: … labels → title (forward), body ← first
            // label (backward via the editor's focus tick).
            let idx = allNames.firstIndex(of: name) ?? 0
            if press.modifiers.contains(.shift) {
                if idx == 0 {
                    focusedLabel = nil
                    editorFocusTick += 1
                } else {
                    moveLabelFocus(-1, in: allNames)
                }
            } else {
                if idx == allNames.count - 1 {
                    focusedLabel = nil
                    titleFocused = true
                } else {
                    moveLabelFocus(1, in: allNames)
                }
            }
            return .handled
        default:
            break
        }
        guard let raw = press.characters.first else { return .ignored }
        switch latinize(raw) {
        case "j": moveLabelFocus(1, in: allNames); return .handled
        case "k": moveLabelFocus(-1, in: allNames); return .handled
        default: return .ignored
        }
    }

    private func toggleLabel(_ name: String) {
        if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
    }

    private func moveLabelFocus(_ delta: Int, in names: [String]) {
        guard !names.isEmpty else { return }
        let cur = focusedLabel.flatMap { names.firstIndex(of: $0) } ?? 0
        let next = min(max(cur + delta, 0), names.count - 1)
        focusedLabel = names[next]
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else { return }
        let diff = labelDiff(original: issue.labels.map(\.name),
                             edited: Array(picked))
        saving = true
        Task { @MainActor in
            let ok = await browser.saveEdit(
                number: issue.number,
                title: trimmed == issue.title ? nil : trimmed,
                body: body_ == issue.body ? nil : body_,
                addLabels: diff.add, removeLabels: diff.remove)
            saving = false
            if ok { browser.screen = .detail(issue.number) }
        }
    }
}
