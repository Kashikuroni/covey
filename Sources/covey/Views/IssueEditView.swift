import SwiftUI
import AppKit

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
        .onChange(of: titleFocused) { _, focused in
            // macOS selects the whole title on focus; drop the caret at the end
            // so a stray keystroke can't wipe it (it carries the system task id).
            guard focused else { return }
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                }
            }
        }
    }

    /// Tab out of the body wraps focus back to the title; the label selector
    /// is reached by click/Tab (it owns its own focus).
    private func switchFromBody(forward: Bool) {
        titleFocused = true
    }

    @ViewBuilder
    private var labelChecklist: some View {
        LabelSelector(tk: tk,
                      labels: browser.labels ?? [],
                      loading: browser.labelsLoading,
                      picked: $picked)
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

/// Searchable multi-select label picker: a collapsed summary row that expands
/// into a fuzzy search + a checkbox list. In the list: `space` toggles the
/// focused row, `⌘A` selects every filtered label (or clears them if all are
/// already picked), `enter`/`esc` close. Shared by the composer and editor.
struct LabelSelector: View {
    let tk: Tokens
    let labels: [GhLabel]
    let loading: Bool
    @Binding var picked: Set<String>

    @State private var expanded = false
    @State private var query = ""
    @State private var focusedName: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var filtered: [GhLabel] {
        query.isEmpty ? labels : labels.filter { fuzzyMatch(query, $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summaryRow
            if expanded { expandedBody }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
            Text("Labels").font(.system(size: IssueFont.body)).foregroundStyle(tk.t2)
            Text(summary).font(.system(size: IssueFont.meta))
                .foregroundStyle(picked.isEmpty ? tk.t4 : tk.accent).lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
        .focusable()
        .onKeyPress(.return) { toggleExpanded(); return .handled }
        .onKeyPress(.space) { toggleExpanded(); return .handled }
        .onTapGesture { toggleExpanded() }
    }

    private var summary: String {
        if loading { return "loading…" }
        if picked.isEmpty { return "none — enter to add" }
        return picked.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private var expandedBody: some View {
        TextField("filter labels", text: $query)
            .focused($searchFocused)
            .ayuField(tk, focused: searchFocused)
            .onKeyPress(.downArrow) { focusList(); return .handled }
            .onSubmit { focusList() }
        if filtered.isEmpty {
            Text(loading ? "loading…" : "no labels")
                .font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered, id: \.name) { label in row(label.name) }
                }
            }
            .frame(maxHeight: 120)
            .focusable()
            .focused($listFocused)
            .onKeyPress(phases: .down) { handleListKey($0) }
        }
        HStack(spacing: 10) {
            KbdBadge(key: "space", label: "toggle", tk: tk)
            KbdBadge(key: "⌘a", label: "all", tk: tk)
            KbdBadge(key: "enter", label: "done", tk: tk)
        }
    }

    private func row(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: picked.contains(name) ? "checkmark.square.fill" : "square")
                .foregroundStyle(picked.contains(name) ? Color.accentColor : .secondary)
            Text(name).font(.system(size: IssueFont.body))
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(focusedName == name ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { toggle(name) }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command), press.key == "a" {
            toggleAll(); return .handled
        }
        switch press.key {
        case .space: toggleFocused(); return .handled
        case .downArrow: moveFocus(1); return .handled
        case .upArrow: moveFocus(-1); return .handled
        case .return, .escape: collapse(); return .handled
        default: break
        }
        guard let raw = press.characters.first else { return .ignored }
        switch latinize(raw) {
        case "j": moveFocus(1); return .handled
        case "k": moveFocus(-1); return .handled
        default: return .ignored
        }
    }

    private func toggleExpanded() {
        expanded.toggle()
        guard expanded else { collapse(); return }
        if focusedName == nil { focusedName = filtered.first?.name }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func focusList() {
        searchFocused = false
        if focusedName == nil || !filtered.contains(where: { $0.name == focusedName }) {
            focusedName = filtered.first?.name
        }
        DispatchQueue.main.async { listFocused = true }
    }

    private func toggle(_ name: String) {
        if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
    }

    private func toggleFocused() { if let n = focusedName { toggle(n) } }

    private func moveFocus(_ delta: Int) {
        let names = filtered.map(\.name)
        guard !names.isEmpty else { return }
        let cur = focusedName.flatMap { names.firstIndex(of: $0) } ?? 0
        focusedName = names[min(max(cur + delta, 0), names.count - 1)]
    }

    /// ⌘A: if every filtered label is already picked, clear them; else add the
    /// rest so all filtered end up selected.
    private func toggleAll() {
        let names = filtered.map(\.name)
        if names.allSatisfy({ picked.contains($0) }) {
            names.forEach { picked.remove($0) }
        } else {
            names.forEach { picked.insert($0) }
        }
    }

    private func collapse() {
        expanded = false
        listFocused = false
        searchFocused = false
    }
}
