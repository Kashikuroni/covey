import AppKit
import SwiftUI
import CoveyKit

private let customAgentSlot = "custom…"

/// Keyboard-first new-session form: a port of the TUI's modal_new mechanics.
/// Enter advances the field chain, ⇧Enter submits, Esc cancels; the directory
/// row has a live subdir picker (↓/↑ walk, Tab/→ descend) — no Finder panel.
struct NewSessionSheet: View {
    let model: AppModel
    @State private var name = ""
    @State private var dir = "~/"
    @State private var terminal = false
    @State private var branchInput = ""
    @State private var branchSelected = 0
    @State private var createWorktree = false
    @State private var baseInput = ""
    @State private var baseSelected = 0
    @State private var currentBranch: String?
    @State private var worktrees: [String: String] = [:]
    @State private var agentChoice: String
    @State private var customAgent = ""
    @State private var claudeModel = "default"
    @State private var effort = "auto"
    @State private var repoRoot: String?
    @State private var branches: [String] = []
    @State private var dirEntries: [String] = []
    @State private var dirSelected = 0
    @State private var error: String?
    @FocusState private var focus: FormField?
    private let presets: [String]

    init(model: AppModel) {
        self.model = model
        let p = CoveyConfig.load().presets
        presets = p
        _agentChoice = State(initialValue: p.first ?? "claude")
    }

    // MARK: - derived

    private var effectiveAgent: String {
        agentChoice == customAgentSlot ? customAgent : agentChoice
    }

    /// Claude detection by the command's first word (covers "claude --flag").
    private var isClaude: Bool {
        effectiveAgent.split(separator: " ").first == "claude"
    }

    private var trimmedBranch: String { branchInput.trimmingCharacters(in: .whitespaces) }

    /// No exact match -> submitting will create this branch.
    private var branchIsNew: Bool {
        !trimmedBranch.isEmpty && !branches.contains(trimmedBranch)
    }

    /// The branch's existing worktree (the main worktree counts) — the
    /// session opens there, so the checkbox disappears.
    private var branchWorktreePath: String? {
        trimmedBranch.isEmpty ? nil : worktrees[trimmedBranch]
    }

    private var showWorktreeToggle: Bool {
        !trimmedBranch.isEmpty && trimmedBranch != currentBranch
            && branchWorktreePath == nil
    }

    private var branchEntries: [String] { filterBranches(branches, query: trimmedBranch) }

    private var baseEntries: [String] {
        filterBranches(branches, query: baseInput.trimmingCharacters(in: .whitespaces))
    }

    private var fieldSequence: [FormField] {
        formFieldSequence(terminal: terminal, isRepo: repoRoot != nil,
                          showWorktreeToggle: showWorktreeToggle,
                          showBase: branchIsNew,
                          isClaude: isClaude,
                          customAgent: agentChoice == customAgentSlot)
    }

    private var commandPreview: String {
        if terminal { return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh" }
        return composeAgentCommand(
            agent: effectiveAgent,
            model: isClaude && claudeModel != "default" ? claudeModel : nil,
            effort: isClaude && effort != "auto" ? effort : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New session").font(.headline)
            TextField("Name (auto if empty)", text: $name)
                .focused($focus, equals: .name)
                .onSubmit { advance(from: .name) }
            dirRow
            toggleRow(.terminal, label: "Plain terminal ($SHELL, no agent)", value: $terminal)
            if repoRoot != nil {
                branchRow
                if showWorktreeToggle {
                    toggleRow(.worktree, label: "Create worktree", value: $createWorktree)
                }
                if branchIsNew {
                    baseRow
                }
            }
            if !terminal {
                cycleRow(.agent, label: "Agent",
                         options: presets + [customAgentSlot], selection: $agentChoice)
                if agentChoice == customAgentSlot {
                    TextField("Custom agent command", text: $customAgent)
                        .focused($focus, equals: .customAgent)
                        .onSubmit { advance(from: .customAgent) }
                }
                if isClaude {
                    cycleRow(.model, label: "Model",
                             options: ["default"] + claudeModels, selection: $claudeModel)
                    cycleRow(.effort, label: "Effort",
                             options: effortLevels(model: claudeModel == "default" ? nil : claudeModel),
                             selection: $effort)
                }
            }
            Text(commandPreview)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("enter next · ⇧enter create · esc cancel")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Create") { submit() }
                    .disabled(dir.isEmpty || (!terminal && effectiveAgent.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            submit()
            return .handled
        }
        .onExitCommand { model.modal = nil }
        .onAppear {
            if let prefill = model.newSessionPrefillDir {
                let collapsed = collapseHome(prefill)
                dir = collapsed.hasSuffix("/") ? collapsed : collapsed + "/"
            }
            model.clearNewSessionPrefill()
            focus = .name
            refreshDirEntries()
        }
        .task(id: dir) {
            refreshDirEntries()
            let info = await model.gitInfo(dir)
            repoRoot = info.repoRoot
            currentBranch = info.currentBranch
            branches = info.branches
            worktrees = info.worktrees
        }
        .onChange(of: branchInput) { _, _ in branchSelected = 0 }
        .onChange(of: baseInput) { _, _ in baseSelected = 0 }
        .onChange(of: claudeModel) { _, m in
            let levels = effortLevels(model: m == "default" ? nil : m)
            if !levels.contains(effort) { effort = "auto" }
        }
        .onChange(of: agentChoice) { _, _ in
            claudeModel = "default"
            effort = "auto"
        }
        .onChange(of: focus) { _, new in
            // macOS selects the whole text when a field gains focus; for the
            // path field that would make the first keystroke wipe "~/" — put
            // the caret at the end instead so typing appends.
            guard new == .dir else { return }
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                }
            }
        }
    }

    // MARK: - rows

    private var dirRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Directory", text: $dir)
                .focused($focus, equals: .dir)
                .onSubmit { advance(from: .dir) }
                .onKeyPress(.downArrow) { step($dirSelected, in: dirEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($dirSelected, in: dirEntries, -1); return .handled }
                .onKeyPress(.tab) { dirDescend() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    // → descends only when a suggestion is highlighted;
                    // otherwise it stays a caret move inside the field.
                    dirEntries.isEmpty ? .ignored : (dirDescend() ? .handled : .ignored)
                }
            if focus == .dir {
                suggestionList(entries: dirEntries, selected: $dirSelected) { _ in
                    _ = dirDescend()
                }
            }
        }
    }

    private var branchRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(currentBranch.map { "branch (current: \($0))" } ?? "branch",
                      text: $branchInput)
                .focused($focus, equals: .branch)
                .onSubmit { advance(from: .branch) }
                .onKeyPress(.downArrow) { step($branchSelected, in: branchEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($branchSelected, in: branchEntries, -1); return .handled }
                .onKeyPress(.tab) { acceptBranch() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    branchEntries.isEmpty ? .ignored : (acceptBranch() ? .handled : .ignored)
                }
            if focus == .branch {
                // ⧉ (the card glyph for worktrees) marks branches checked out
                // in a linked worktree — picking one opens the session there.
                suggestionList(entries: branchEntries, selected: $branchSelected,
                               annotate: { worktrees[$0] != nil && $0 != currentBranch
                                           ? "⧉" : nil }) {
                    branchInput = $0
                }
                if branchIsNew {
                    Text("will create branch \"\(trimmedBranch)\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let path = branchWorktreePath {
                Text("opens in: \(collapseHome(path))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var baseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(currentBranch.map { "base (default: \($0))" } ?? "base",
                      text: $baseInput)
                .focused($focus, equals: .base)
                .onSubmit { advance(from: .base) }
                .onKeyPress(.downArrow) { step($baseSelected, in: baseEntries, 1); return .handled }
                .onKeyPress(.upArrow) { step($baseSelected, in: baseEntries, -1); return .handled }
                .onKeyPress(.tab) { acceptBase() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    baseEntries.isEmpty ? .ignored : (acceptBase() ? .handled : .ignored)
                }
            if focus == .base {
                suggestionList(entries: baseEntries, selected: $baseSelected) {
                    baseInput = $0
                }
            }
        }
    }

    /// The dir-picker's suggestion dropdown, shared by the branch/base rows:
    /// first 8 entries, highlight, click-to-pick, "… N more" tail. `annotate`
    /// returns an optional dimmed marker glyph shown after an entry's name.
    @ViewBuilder
    private func suggestionList(entries: [String], selected: Binding<Int>,
                                annotate: @escaping (String) -> String? = { _ in nil },
                                pick: @escaping (String) -> Void) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.offset) { idx, entry in
                    HStack(spacing: 4) {
                        Text(entry)
                        if let mark = annotate(entry) {
                            Text(mark).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(idx == selected.wrappedValue
                                ? Color.accentColor.opacity(0.2) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selected.wrappedValue = idx; pick(entry) }
                }
                if entries.count > 8 {
                    Text("… \(entries.count - 8) more")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
                }
            }
        }
    }

    private func toggleRow(_ field: FormField, label: String, value: Binding<Bool>) -> some View {
        // A custom checkbox glyph, NOT a system Toggle: the row is the single
        // tab stop (an inner Toggle adds its own, and its Space handling would
        // fight the row's).
        HStack(spacing: 8) {
            Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                .foregroundStyle(value.wrappedValue ? Color.accentColor : .secondary)
            Text(label).font(.callout)
            Spacer()
        }
        .padding(2)
        .contentShape(Rectangle())
        .background(focus == field ? Color.accentColor.opacity(0.12) : .clear)
        .focusable()
        .focused($focus, equals: field)
        .onKeyPress(.space) { value.wrappedValue.toggle(); return .handled }
        .onKeyPress(.leftArrow) { value.wrappedValue.toggle(); return .handled }
        .onKeyPress(.rightArrow) { value.wrappedValue.toggle(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift) else { return .ignored }
            advance(from: field)
            return .handled
        }
        .onTapGesture {
            value.wrappedValue.toggle()
            focus = field
        }
    }

    private func cycleRow(_ field: FormField, label: String,
                          options: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 60, alignment: .leading)
                .font(.callout).foregroundStyle(.secondary)
            ForEach(options, id: \.self) { option in
                Text(option)
                    .font(.callout)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(selection.wrappedValue == option
                                ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 4))
                    .onTapGesture { selection.wrappedValue = option; focus = field }
            }
            Spacer()
        }
        .padding(2)
        .background(focus == field ? Color.accentColor.opacity(0.12) : .clear)
        .focusable()
        .focused($focus, equals: field)
        .onKeyPress(.rightArrow) { cycle(options, selection, 1); return .handled }
        .onKeyPress(.leftArrow) { cycle(options, selection, -1); return .handled }
        .onKeyPress(.space) { cycle(options, selection, 1); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift) else { return .ignored }
            advance(from: field)
            return .handled
        }
    }

    // MARK: - behavior

    /// TUI cycle with wrap.
    private func cycle(_ options: [String], _ selection: Binding<String>, _ delta: Int) {
        guard !options.isEmpty else { return }
        let cur = options.firstIndex(of: selection.wrappedValue) ?? 0
        let next = ((cur + delta) % options.count + options.count) % options.count
        selection.wrappedValue = options[next]
    }

    private func advance(from field: FormField) {
        let seq = fieldSequence
        guard let idx = seq.firstIndex(of: field) else { return }
        if idx + 1 < seq.count {
            focus = seq[idx + 1]
        } else {
            submit()
        }
    }

    private func refreshDirEntries() {
        let (basePath, filter) = DirBrowse.splitPath(dir)
        dirEntries = DirBrowse.list(base: expandTilde(basePath), filter: filter)
        dirSelected = 0
    }

    /// ↓/↑ over a suggestion list with wrap (the TUI picker's walk).
    private func step(_ selected: Binding<Int>, in entries: [String], _ delta: Int) {
        guard !entries.isEmpty else { return }
        selected.wrappedValue = ((selected.wrappedValue + delta) % entries.count
                                 + entries.count) % entries.count
    }

    @discardableResult
    private func acceptBranch() -> Bool {
        guard focus == .branch, branchEntries.indices.contains(branchSelected)
        else { return false }
        branchInput = branchEntries[branchSelected]
        return true
    }

    @discardableResult
    private func acceptBase() -> Bool {
        guard focus == .base, baseEntries.indices.contains(baseSelected)
        else { return false }
        baseInput = baseEntries[baseSelected]
        return true
    }

    @discardableResult
    private func dirDescend() -> Bool {
        guard focus == .dir, dirEntries.indices.contains(dirSelected) else { return false }
        let (basePath, _) = DirBrowse.splitPath(dir)
        dir = basePath + dirEntries[dirSelected] + "/"
        return true
    }

    private func submit() {
        error = nil
        let cleanDir = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty,
           let err = validateCreate(name: trimmedName, dir: cleanDir,
                                    existing: model.sessions.map(\.name)) {
            error = err
            return
        }
        var worktree: WorktreeSpec?
        if repoRoot != nil {
            if branchIsNew {
                if let err = validateBranch(trimmedBranch) { error = err; return }
                let trimmedBase = baseInput.trimmingCharacters(in: .whitespaces)
                if !trimmedBase.isEmpty && !branches.contains(trimmedBase) {
                    error = "base branch not found: \(trimmedBase)"; return
                }
            }
            worktree = branchPlan(input: branchInput, current: currentBranch,
                                  branches: branches, worktrees: worktrees,
                                  createWorktree: createWorktree, base: baseInput)
        }
        let spec = (name: trimmedName.isEmpty ? nil : trimmedName,
                    dir: expandTilde(cleanDir),
                    agent: effectiveAgent,
                    terminal: terminal,
                    worktree: worktree,
                    model: isClaude && claudeModel != "default" ? claudeModel : nil,
                    effort: isClaude && effort != "auto" ? effort : nil)
        Task {
            if let err = await model.createFull(name: spec.name, dir: spec.dir,
                                                agent: spec.agent, terminal: spec.terminal,
                                                worktree: spec.worktree, model: spec.model,
                                                effort: spec.effort) {
                error = err
            } else {
                model.modal = nil
            }
        }
    }
}
