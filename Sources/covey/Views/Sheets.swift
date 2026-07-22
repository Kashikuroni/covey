import AppKit
import SwiftUI
import CoveyKit

extension AppModel.Modal: Identifiable {
    public var id: String {
        switch self {
        case .newSession: return "new"
        case .recent: return "recent"
        case .kill(let name): return "kill-\(name)"
        case .rename(let name): return "rename-\(name)"
        case .renameProject(let dir): return "rename-project-\(dir)"
        case .promote(let name): return "promote-\(name)"
        case .deleteBranch(let name): return "delete-branch-\(name)"
        case .cleanup(let dir): return "cleanup-\(dir)"
        case .restart(let name): return "restart-\(name)"
        case .restartAll: return "restart-all"
        case .themeRestart: return "theme-restart"
        case .addProject: return "add-project"
        }
    }
}

/// Recently-stopped sessions: search, j/k navigation, multi-restore with h,
/// and Enter to restore and focus the Agent pane.
struct RecentSheet: View {
    let model: AppModel
    @State private var state = RecentSheetState()
    @State private var retainedSessions: [RecentSession] = []
    @FocusState private var focused: RecentSheetFocus?

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var candidates: [RecentSearchItem] {
        recentSearchItems(current: model.visibleRecents(), retaining: retainedSessions) { root in
            model.displayName(forDir: root)
        }
    }
    /// A restoring row is retained until the create response arrives because
    /// sessionAdded can be delivered first and hide it from visibleRecents.
    private var rows: [RecentSearchItem] { state.results(from: candidates) }
    private var maximumScreenHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return screen?.visibleFrame.height ?? 900
    }
    private var height: CGFloat {
        recentSheetHeight(rowCount: rows.count, screenHeight: maximumScreenHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent sessions").font(.headline)
            TextField("Search sessions, branches, projects", text: $state.query)
                .focused($focused, equals: .search)
                .ayuField(tk, focused: focused == .search)
                .onSubmit {
                    state.commitSearch(rows: rows)
                    focused = .list
                }
                .onExitCommand {
                    state.query = ""
                    state.commitSearch(rows: state.results(from: candidates))
                    focused = .list
                }
            resultsList
            HStack(spacing: 10) {
                KbdBadge(key: "/", label: "search", tk: tk)
                KbdBadge(key: "j/k", label: "move", tk: tk)
                KbdBadge(key: "h", label: "restore", tk: tk)
                KbdBadge(key: "enter", label: "open", tk: tk)
            }
        }
        .padding(20)
        .frame(width: 480, height: height)
        .focusEffectDisabled()
        .onAppear {
            state.open(rows: recentResults(candidates, query: state.query))
            focused = .list
        }
        .onChange(of: state.query) { _, _ in state.reconcile(rows: rows) }
        .onChange(of: focused) { _, value in
            if value == .search {
                state.focusSearch()
            } else if value == .list {
                state.commitSearch(rows: rows)
            }
        }
        .onExitCommand { model.modal = nil }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty {
                    Text("no recently-stopped sessions")
                        .font(.caption).foregroundStyle(tk.t4)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVStack(spacing: 5) {
                        ForEach(rows) { item in
                            RecentResultCard(
                                item: item,
                                current: item.id == state.selectedName,
                                restoring: state.restoringNames.contains(item.id),
                                failureTrigger: state.failureTriggers[item.id, default: 0],
                                now: Int64(Date().timeIntervalSince1970), tk: tk)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { restore(item, activate: true) }
                            .transition(.asymmetric(
                                insertion: .identity,
                                removal: .offset(x: -48)
                                    .combined(with: .scale(scale: 0.72, anchor: .leading))
                                    .combined(with: .opacity)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.14), value: rows.map(\.id))
                }
            }
            .focusable()
            .focused($focused, equals: .list)
            .onChange(of: state.selectedName) { _, name in
                if let name {
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
            }
        }
        .onKeyPress(phases: .down) { press in
            guard focused == .list else { return .ignored }
            switch latinize(press.characters.first ?? " ") {
            case "j": state.move(1, rows: rows); return .handled
            case "k": state.move(-1, rows: rows); return .handled
            case "/": state.focusSearch(); focused = .search; return .handled
            case "h": restoreSelected(activate: false); return .handled
            default: return .ignored
            }
        }
        .onKeyPress(.downArrow) {
            guard focused == .list else { return .ignored }
            state.move(1, rows: rows); return .handled
        }
        .onKeyPress(.upArrow) {
            guard focused == .list else { return .ignored }
            state.move(-1, rows: rows); return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            guard focused == .list else { return .ignored }
            restoreSelected(activate: true); return .handled
        }
    }

    private func restoreSelected(activate: Bool) {
        guard let item = rows.first(where: { $0.id == state.selectedName }) else { return }
        restore(item, activate: activate)
    }

    private func restore(_ item: RecentSearchItem, activate: Bool) {
        let visibleBefore = rows
        guard state.beginRestore(item.id) else { return }
        retainedSessions.append(item.session)
        Task {
            let succeeded = await model.relaunchRecent(item.session, activate: activate)
            if succeeded && activate {
                model.modal = nil
            } else if succeeded {
                let visibleNow = rows
                withAnimation(.easeInOut(duration: 0.14)) {
                    state.completeRestore(item.id, succeeded: true,
                                          visibleBefore: visibleBefore,
                                          visibleNow: visibleNow)
                    retainedSessions.removeAll { $0.name == item.id }
                }
                focused = .list
            } else {
                let visibleNow = rows
                state.completeRestore(item.id, succeeded: false,
                                      visibleBefore: visibleBefore,
                                      visibleNow: visibleNow)
                retainedSessions.removeAll { $0.name == item.id }
                focused = .list
            }
        }
    }
}

private struct RecentRestoreFailureEffect: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = -12 * abs(sin(phase * .pi))
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

private struct RecentResultCard: View {
    let item: RecentSearchItem
    let current: Bool
    let restoring: Bool
    let failureTrigger: Int
    let now: Int64
    let tk: Tokens
    @State private var failurePhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AgentIcon(agent: item.session.agent, tk: tk)
                Text(item.session.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(current ? tk.t1 : tk.t2)
                    .lineLimit(1)
                if item.session.resumeCmd != nil {
                    Text("↻").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                        .help("relaunch resumes the conversation")
                }
                Spacer()
                if let stopped = item.session.stoppedAt {
                    Text(humanizeAge(now - stopped))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                }
            }
            HStack(spacing: 6) {
                Text(item.projectName)
                if let branch = item.session.branch {
                    Text("·").foregroundStyle(tk.t4)
                    Text(branch)
                }
                Spacer()
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tk.t3)
            .lineLimit(1)
            Text(collapseHome(item.session.dir))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tk.t4)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(RoundedRectangle(cornerRadius: Tokens.r)
            .strokeBorder(current ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(current ? tk.t1 : .clear)
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .opacity(restoring ? 0.72 : 1)
        .modifier(RecentRestoreFailureEffect(phase: failurePhase))
        .onChange(of: failureTrigger) { _, _ in
            withAnimation(.easeInOut(duration: 0.20)) { failurePhase += 1 }
        }
    }
}

struct RestartSheet: View {
    let model: AppModel
    let name: String
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restart \"\(name)\"?").font(.headline)
            Text("claude resumes the conversation; other agents relaunch fresh.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart") {
                    Task {
                        if let err = await model.restart(name) { error = err }
                        else { model.modal = nil }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct RestartAllSheet: View {
    let model: AppModel
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restart all claude sessions?").font(.headline)
            Text("Each claude session exits and resumes its conversation. Type yes to confirm.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("yes", text: $confirmation)
                .ayuField(Tokens(Theme(raw: model.themeRaw)), focused: true)
                .onSubmit { if confirmsRestart(confirmation) { run() } }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart all") { run() }
                    .buttonStyle(.glassProminent)
                    .disabled(!confirmsRestart(confirmation))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func run() {
        Task {
            let errors = await model.restartAllClaude()
            if errors.isEmpty { model.modal = nil }
            else { error = errors.joined(separator: " · ") }
        }
    }
}

/// Offered after a theme toggle: claude reads its palette once at startup,
/// so live agents keep the old colors until restarted. Idle agents restart
/// on confirm (the plan is recomputed then); busy ones are listed, untouched.
struct ThemeRestartSheet: View {
    let model: AppModel
    @State private var error: String?

    var body: some View {
        let plan = themeRestartPlan(sessions: model.visibleSessions,
                                    statuses: model.statusByName)
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply theme to agents?").font(.headline)
            Text("Idle agents restart and resume their conversation; busy ones keep the old theme until restarted by hand (space s u).")
                .font(.caption).foregroundStyle(.secondary)
            if !plan.idle.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Will restart").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.idle, id: \.self) { name in
                        Text("• \(name)").font(.caption)
                    }
                }
            }
            if !plan.busy.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keeps old theme").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.busy, id: \.self) { name in
                        Text("• \(name) — \(model.statusByName[name]?.rawValue ?? "busy")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Restart \(plan.idle.count)") { run() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.idle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func run() {
        Task {
            let errors = await model.restartIdleClaude()
            if errors.isEmpty { model.modal = nil }
            else { error = errors.joined(separator: " · ") }
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
                Button("Promote") { confirm() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
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
                    .buttonStyle(.glassProminent)
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
                    .buttonStyle(.glassProminent)
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
                .ayuField(Tokens(Theme(raw: model.themeRaw)), focused: true)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    model.setProjectName(dir: dir, name: name)
                    model.modal = nil
                }
                .buttonStyle(.glassProminent)
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
    @State private var deleteBranch = false
    @State private var branchGate: BranchGate = .loading

    private enum BranchGate: Equatable {
        case loading
        case blocked(String)   // caption explaining why delete is unavailable
        case allowed
    }

    private var isWorktree: Bool {
        model.sessions.first(where: { $0.name == name })?.worktreeRepo != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kill session \"\(name)\"?").font(.headline)
            if isWorktree {
                Toggle("Also remove the git worktree", isOn: $removeWorktree)
                    .onChange(of: removeWorktree) { _, on in
                        if !on { deleteBranch = false }   // can't delete a live worktree's branch
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Also delete the branch", isOn: $deleteBranch)
                        .disabled(branchGate != .allowed)
                        .onChange(of: deleteBranch) { _, on in
                            if on { removeWorktree = true }   // delete needs the tree gone
                        }
                    if case let .blocked(reason) = branchGate {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Kill", role: .destructive) {
                    let rm = removeWorktree
                    let del = deleteBranch
                    Task {
                        await model.kill(name, removeWorktree: rm, deleteBranch: del)
                        model.modal = nil
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task {
            guard isWorktree else { return }
            guard let st = await model.branchStatus(name: name) else {
                branchGate = .blocked("Branch status unavailable"); return
            }
            if st.dirty { branchGate = .blocked("Uncommitted changes") }
            else if !st.merged { branchGate = .blocked("Unmerged commits") }
            else { branchGate = .allowed }
        }
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
                .ayuField(Tokens(Theme(raw: model.themeRaw)), focused: true)
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
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { newName = name }
    }
}

/// Keyboard-first "add project": a path input with a live subdir picker
/// (↓/↑ walk, Tab/→ descend), mirroring the new-session directory row — no
/// Finder panel. Enter registers the directory as a project and selects it.
struct AddProjectSheet: View {
    let model: AppModel
    @State private var dir = "~/"
    @State private var entries: [String] = []
    @State private var selected = 0
    @State private var error: String?
    @FocusState private var focused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add project").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Directory", text: $dir)
                    .focused($focused)
                    .ayuField(tk, focused: focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.tab) { descend() ? .handled : .ignored }
                    .onKeyPress(.rightArrow, phases: .down) { _ in
                        // → descends only when a suggestion is highlighted;
                        // otherwise it stays a caret move inside the field.
                        entries.isEmpty ? .ignored : (descend() ? .handled : .ignored)
                    }
                if focused { suggestions }
            }
            if let error {
                Text("! \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("↑↓ pick · tab/→ enter dir · enter add · esc cancel")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Add") { submit() }
                    .buttonStyle(.glassProminent)
                    .disabled(dir.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { model.modal = nil }
        .onAppear { focused = true; refresh() }
        .task(id: dir) { refresh() }
        .onChange(of: focused) { _, new in
            // macOS selects the whole field on focus; put the caret at the end
            // so the first keystroke appends to "~/" instead of wiping it.
            guard new else { return }
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                }
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.offset) { idx, entry in
                    HStack(spacing: 4) {
                        Text(entry)
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(idx == selected ? Color.accentColor.opacity(0.2) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = idx; _ = descend() }
                }
                if entries.count > 8 {
                    Text("… \(entries.count - 8) more")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
                }
            }
        }
    }

    private func refresh() {
        let (basePath, filter) = DirBrowse.splitPath(dir)
        entries = DirBrowse.list(base: expandTilde(basePath), filter: filter)
        selected = 0
    }

    private func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selected = ((selected + delta) % entries.count + entries.count) % entries.count
    }

    @discardableResult
    private func descend() -> Bool {
        guard entries.indices.contains(selected) else { return false }
        let (basePath, _) = DirBrowse.splitPath(dir)
        dir = basePath + entries[selected] + "/"
        return true
    }

    private func submit() {
        let cleanDir = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        let path = expandTilde(cleanDir)
        var isDir: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { error = "not a directory"; return }
        model.addProject(path)
        model.modal = nil
    }
}
