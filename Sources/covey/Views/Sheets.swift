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
        }
    }
}

/// Recently-stopped sessions: cards, `/` filter over name+dir, j/k, Enter
/// relaunches (claude resumes its conversation via the stored resumeCmd).
struct RecentSheet: View {
    let model: AppModel
    @State private var cursor = 0
    @State private var filter = ""
    @State private var filtering = false
    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var items: [RecentSession] {
        filterRecents(model.visibleRecents(), filter: filter)
    }

    var body: some View {
        let rows = items
        let now = Int64(Date().timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent sessions").font(.headline)
            if rows.isEmpty {
                Text("no recently-stopped sessions")
                    .font(.caption).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.element.name) { idx, r in
                        card(r, now: now, current: idx == cursor)
                            .onTapGesture { relaunch(r) }
                    }
                }
            }
            if filtering {
                HStack(spacing: 6) {
                    Text("/").font(.caption.monospaced()).foregroundStyle(tk.accent)
                    TextField("filter", text: $filter)
                        .focused($filterFocused)
                        .ayuField(tk, focused: filterFocused)
                        .onSubmit { relaunchAtCursor() }
                        .onExitCommand {
                            filter = ""; filtering = false; listFocused = true
                        }
                }
            } else {
                Text("j/k move · enter restore · / filter · esc close")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 480)
        .focusable()
        // Sheets live in their own window: the root focusEffectDisabled()
        // does not reach here, so kill the blue focus ring locally.
        .focusEffectDisabled()
        .focused($listFocused)
        .onAppear { listFocused = true }
        .onKeyPress(phases: .down) { press in
            guard !filterFocused else { return .ignored }
            switch latinize(press.characters.first ?? " ") {
            case "j": move(1); return .handled
            case "k": move(-1); return .handled
            case "/": filtering = true; filterFocused = true; return .handled
            default: return .ignored
            }
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return, phases: .down) { _ in
            guard !filterFocused else { return .ignored }   // onSubmit handles it
            relaunchAtCursor(); return .handled
        }
        .onExitCommand { model.modal = nil }
        .onChange(of: filter) { _, _ in
            cursor = min(cursor, max(0, items.count - 1))
        }
    }

    private func card(_ r: RecentSession, now: Int64, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AgentIcon(agent: r.agent, tk: tk)
                Text(r.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(current ? tk.t1 : tk.t2).lineLimit(1)
                if r.resumeCmd != nil {
                    Text("↻").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                        .help("relaunch resumes the conversation")
                }
                Spacer()
                if let stopped = r.stoppedAt {
                    Text(humanizeAge(now - stopped))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tk.t4)
                }
            }
            Text(collapseHome(r.dir))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tk.t3).lineLimit(1).truncationMode(.head)
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? tk.cardHover : tk.card,
                    in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(current ? tk.bd3 : tk.bd))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(current ? tk.t1 : .clear)
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        cursor = ((cursor + delta) % count + count) % count
    }

    private func relaunchAtCursor() {
        let rows = items
        guard rows.indices.contains(cursor) else { return }
        relaunch(rows[cursor])
    }

    private func relaunch(_ r: RecentSession) {
        Task {
            await model.relaunchRecent(r)
            model.modal = nil
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
                .buttonStyle(.glassProminent)
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
