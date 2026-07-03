import AppKit
import SwiftUI
import CoveyKit

extension AppModel.Modal: Identifiable {
    public var id: String {
        switch self {
        case .newSession: return "new"
        case .kill(let name): return "kill-\(name)"
        case .rename(let name): return "rename-\(name)"
        case .renameProject(let dir): return "rename-project-\(dir)"
        case .promote(let name): return "promote-\(name)"
        case .deleteBranch(let name): return "delete-branch-\(name)"
        case .cleanup(let dir): return "cleanup-\(dir)"
        }
    }
}

private let customAgentSlot = "custom…"
private let newBranchSlot = "+ new branch"

/// Keyboard-first new-session form: a port of the TUI's modal_new mechanics.
/// Enter advances the field chain, ⇧Enter submits, Esc cancels; the directory
/// row has a live subdir picker (↓/↑ walk, Tab/→ descend) — no Finder panel.
struct NewSessionSheet: View {
    let model: AppModel
    @State private var name = ""
    @State private var dir = "~/"
    @State private var terminal = false
    @State private var useWorktree = false
    @State private var branchChoice = newBranchSlot
    @State private var newBranch = ""
    @State private var base = ""
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

    private var fieldSequence: [FormField] {
        formFieldSequence(terminal: terminal, isRepo: repoRoot != nil,
                          useWorktree: useWorktree,
                          creatingNewBranch: branchChoice == newBranchSlot,
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
                toggleRow(.worktree, label: "Run in a git worktree", value: $useWorktree)
                if useWorktree {
                    cycleRow(.branch, label: "Branch",
                             options: [newBranchSlot] + branches, selection: $branchChoice)
                    if branchChoice == newBranchSlot {
                        TextField("New branch name", text: $newBranch)
                            .focused($focus, equals: .branch)
                            .onSubmit { advance(from: .branch) }
                        cycleRow(.base, label: "Base", options: branches, selection: $base)
                    }
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
            branches = info.branches
            if base.isEmpty || !info.branches.contains(base) {
                base = info.currentBranch ?? info.branches.first ?? ""
            }
            if branchChoice != newBranchSlot, !info.branches.contains(branchChoice) {
                branchChoice = newBranchSlot
            }
            if info.repoRoot == nil { useWorktree = false }
        }
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
                .onKeyPress(.downArrow) { dirStep(1); return .handled }
                .onKeyPress(.upArrow) { dirStep(-1); return .handled }
                .onKeyPress(.tab) { dirDescend() ? .handled : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { _ in
                    // → descends only when a suggestion is highlighted;
                    // otherwise it stays a caret move inside the field.
                    dirEntries.isEmpty ? .ignored : (dirDescend() ? .handled : .ignored)
                }
            if focus == .dir, !dirEntries.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(dirEntries.prefix(8).enumerated()), id: \.offset) { idx, entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(idx == dirSelected
                                        ? Color.accentColor.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { dirSelected = idx; _ = dirDescend() }
                    }
                    if dirEntries.count > 8 {
                        Text("… \(dirEntries.count - 8) more")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
                    }
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

    private func dirStep(_ delta: Int) {
        guard !dirEntries.isEmpty else { return }
        dirSelected = ((dirSelected + delta) % dirEntries.count + dirEntries.count)
            % dirEntries.count
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
        if useWorktree, repoRoot != nil {
            if branchChoice == newBranchSlot {
                if let err = validateBranch(newBranch) { error = err; return }
                worktree = .new(branch: newBranch.trimmingCharacters(in: .whitespaces),
                                base: base)
            } else {
                worktree = .existing(branch: branchChoice)
            }
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

struct PromoteSheet: View {
    let model: AppModel
    let name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    private var session: Session? { model.sessions.first { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Promote worktree to root?").font(.headline)
            if let s = session {
                Text("\(s.git?.branch ?? "?") · \(s.dir)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Uncommitted changes move to the repo root via a stash; the worktree is removed.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("y promote · n cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Promote") { confirm() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.init("y")) { confirm(); return .handled }
        .onKeyPress(.init("n")) { model.modal = nil; return .handled }
        .onExitCommand { model.modal = nil }
    }

    private func confirm() {
        Task {
            if let err = await model.promote(name: name) { error = err }
            else { model.modal = nil }
        }
    }
}

struct DeleteBranchSheet: View {
    let model: AppModel
    let name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    private var branch: String {
        model.sessions.first { $0.name == name }?.git?.branch ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete branch '\(branch)'?").font(.headline)
            Text("git branch -d — merged branches only.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("y delete · n cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Delete", role: .destructive) { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.init("y")) { confirm(); return .handled }
        .onKeyPress(.init("n")) { model.modal = nil; return .handled }
        .onExitCommand { model.modal = nil }
    }

    private func confirm() {
        guard let s = model.sessions.first(where: { $0.name == name }),
              let branch = s.git?.branch else { model.modal = nil; return }
        Task {
            if let err = await model.deleteBranch(dir: s.dir, branch: branch) { error = err }
            else { model.modal = nil }
        }
    }
}

struct CleanupSheet: View {
    let model: AppModel
    let dir: String
    @State private var branches: [String] = []
    @State private var selected: Set<String> = []
    @State private var cursor = 0
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup merged branches").font(.headline)
            if !loaded {
                Text("loading…").font(.caption).foregroundStyle(.secondary)
            } else if branches.isEmpty {
                Text("no merged branches").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(branches.enumerated()), id: \.element) { idx, branch in
                        let locked = protectedBranches.contains(branch)
                        HStack(spacing: 6) {
                            Text(idx == cursor ? "›" : " ")
                                .foregroundStyle(.orange).fontWeight(.bold)
                            Text(locked ? "🔒" : (selected.contains(branch) ? "☑" : "☐"))
                            Text(branch).foregroundStyle(locked ? .secondary : .primary)
                        }
                        .font(.callout.monospaced())
                        .contentShape(Rectangle())
                        .onTapGesture {
                            cursor = idx
                            if !locked { toggle(branch) }
                        }
                    }
                }
            }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("j/k move · space toggle · a all · y delete · esc cancel")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Delete selected") { confirm() }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .focusable()
        .focused($focused)
        .task {
            branches = await model.mergedBranches(dir: dir)
            selected = Set(branches.filter { !protectedBranches.contains($0) })
            loaded = true
            focused = true
        }
        .onKeyPress(.init("j")) { move(1); return .handled }
        .onKeyPress(.init("k")) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.space) { toggleAtCursor(); return .handled }
        .onKeyPress(.init("a")) {
            selected = Set(branches.filter { !protectedBranches.contains($0) })
            return .handled
        }
        .onKeyPress(.init("y")) { confirm(); return .handled }
        .onKeyPress(.return, phases: .down) { _ in confirm(); return .handled }
        .onExitCommand { model.modal = nil }
    }

    private func move(_ delta: Int) {
        guard !branches.isEmpty else { return }
        cursor = ((cursor + delta) % branches.count + branches.count) % branches.count
    }

    private func toggleAtCursor() {
        guard branches.indices.contains(cursor) else { return }
        let branch = branches[cursor]
        guard !protectedBranches.contains(branch) else { return }
        toggle(branch)
    }

    private func toggle(_ branch: String) {
        if selected.contains(branch) { selected.remove(branch) } else { selected.insert(branch) }
    }

    private func confirm() {
        guard !selected.isEmpty else { return }
        Task {
            if let err = await model.cleanupBranches(dir: dir, branches: Array(selected)) {
                error = err
                branches = await model.mergedBranches(dir: dir)
                selected.formIntersection(branches)
            } else {
                model.modal = nil
            }
        }
    }
}

struct RenameProjectSheet: View {
    let model: AppModel
    let dir: String
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename project").font(.headline)
            Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField("Display name (empty resets)", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    model.setProjectName(dir: dir, name: name)
                    model.modal = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = model.projectNames[dir] ?? "" }
    }
}

struct KillSheet: View {
    let model: AppModel
    let name: String
    @State private var removeWorktree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kill session \"\(name)\"?").font(.headline)
            if model.sessions.first(where: { $0.name == name })?.worktreeRepo != nil {
                Toggle("Also remove the git worktree", isOn: $removeWorktree)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Kill", role: .destructive) {
                    let rm = removeWorktree
                    Task {
                        await model.kill(name, removeWorktree: rm)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct RenameSheet: View {
    let model: AppModel
    let name: String
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \"\(name)\"").font(.headline)
            TextField("New name", text: $newName)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    let target = newName
                    Task {
                        await model.rename(name, to: target)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { newName = name }
    }
}
