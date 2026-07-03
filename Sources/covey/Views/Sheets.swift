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
