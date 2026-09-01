import Foundation
import CoveyKit

/// Workspace Views on `AppModel`: the `views` / `viewOfSession` maps live on
/// `AppModel` itself (an `@Observable` class needs its stored properties there);
/// everything that reads or mutates them lives here.
extension AppModel {
    // MARK: - Lookups

    var activeViewID: ViewID? { selected.flatMap { viewOfSession[$0] } }
    var activeView: WorkspaceView? { activeViewID.flatMap { views[$0] } }

    func viewForSession(_ name: String) -> WorkspaceView? {
        viewOfSession[name].flatMap { views[$0] }
    }

    // MARK: - Mutation

    /// Mutate the active view in place and persist.
    func mutateActiveView(_ body: (inout WorkspaceView) -> Void) {
        guard let id = activeViewID else { return }
        mutateForView(id, body)
    }

    /// Mutate a view by id in place and persist.
    func mutateForView(_ id: ViewID, _ body: (inout WorkspaceView) -> Void) {
        guard var v = views[id] else { return }
        body(&v)
        views[id] = v
        persistWorkspaceViews()
    }

    /// New standalone single-leaf view for a session that has none.
    func ensureView(for session: String) {
        guard viewOfSession[session] == nil else { return }
        let id = newViewID()
        views[id] = .single(session, id: id)
        viewOfSession[session] = id
    }

    /// Detaches a session from its current view (for a split-merge move). The
    /// caller re-maps `viewOfSession` afterwards. Deletes an emptied view and
    /// kills its shell.
    func dropView(of session: String) async {
        guard let id = viewOfSession[session], var v = views[id] else { return }
        let r = v.removeLeaf(session)
        viewOfSession[session] = nil
        if r.emptied {
            if let shell = v.terminal?.shellSession { await kill(shell) }
            views[id] = nil
        } else {
            views[id] = v
        }
        persistWorkspaceViews()
    }

    /// A session vanished (kill / `.exited`). Drop its leaf; delete the view
    /// (killing its shell) when it empties. Returns the focus successor within a
    /// surviving multi-leaf view.
    @discardableResult
    func removeSessionFromView(_ name: String) -> String? {
        guard let id = viewOfSession[name], var v = views[id] else { return nil }
        let r = v.removeLeaf(name)
        viewOfSession[name] = nil
        if r.emptied {
            if let shell = v.terminal?.shellSession { Task { await kill(shell) } }
            views[id] = nil
        } else {
            views[id] = v
        }
        persistWorkspaceViews()
        return r.successor
    }

    /// Rename a leaf: rewrite the tree and move the `viewOfSession` key.
    func renameSessionInView(_ old: String, to new: String) {
        guard let id = viewOfSession[old], var v = views[id] else { return }
        v.renameLeaf(old, to: new)
        views[id] = v
        viewOfSession[old] = nil
        viewOfSession[new] = id
        persistWorkspaceViews()
    }

    /// Close the active view's terminal zone and kill its shell. The view lives.
    func closeActiveTerminal() {
        guard let id = activeViewID, let v = views[id], v.terminal != nil else { return }
        let shell = v.terminal?.shellSession
        mutateForView(id) { $0.terminal = nil }
        if let shell { Task { await kill(shell) } }
    }

    func persistWorkspaceViews() {
        persisted.workspaceViews = views.values
            .sorted { $0.id < $1.id }
            .map(\.persisted)
        persisted.viewOfSession = viewOfSession
        store.save(persisted)
    }

    // MARK: - Startup: load / migrate / sanitize

    /// Load persisted views, or migrate the legacy layout on first run. Then
    /// sanitize dead leaves / shells.
    func loadOrMigrateViews() {
        if let pv = persisted.workspaceViews {
            for p in pv {
                let v = WorkspaceView(persisted: p)
                views[v.id] = v
                for leaf in v.leaves { viewOfSession[leaf] = v.id }
            }
        } else {
            migrateLegacyLayout()
        }
        sanitizeViews()
        persistWorkspaceViews()
    }

    private func migrateLegacyLayout() {
        let live = Set(sessions.filter { $0.companionOf == nil && $0.hidden != true }.map(\.name))
        for name in live { ensureView(for: name) }

        guard let legacy = persisted.splitTree.map(PaneNode.init(persisted:)) else {
            attachLegacyShell(toViewOf: legacyShellParent())
            clearLegacyFields()
            return
        }
        let leaves = legacy.leaves.filter { live.contains($0) }
        guard leaves.count >= 2 else {
            attachLegacyShell(toViewOf: legacyShellParent())
            clearLegacyFields()
            return
        }
        // Merge the legacy tree's leaves into one view.
        let id = newViewID()
        for leaf in leaves {
            if let old = viewOfSession[leaf], old != id { views[old] = nil }
            viewOfSession[leaf] = id
        }
        var v = WorkspaceView(id: id,
                              agentTree: sanitizedTree(legacy, live: Set(leaves)),
                              terminal: nil,
                              inspector: persisted.showInspector == true
                                ? .shown(mode: persisted.inspectorMode == "trace" ? .trace : .issues)
                                : .hidden,
                              agentAreaRatio: persisted.companionRatio ?? 1.0)
        if let shell = persisted.companionShell,
           sessions.contains(where: { $0.name == shell }) {
            v.terminal = TerminalZone(shellSession: shell)
        }
        views[id] = v
        clearLegacyFields()
    }

    /// The agent session a legacy `companionShell` was anchored to.
    private func legacyShellParent() -> String? {
        guard let shell = persisted.companionShell else { return nil }
        return sessions.first { $0.name == shell }?.companionOf
    }

    private func attachLegacyShell(toViewOf parent: String?) {
        guard let shell = persisted.companionShell,
              sessions.contains(where: { $0.name == shell }) else { return }
        let target = parent.flatMap { viewOfSession[$0] } ?? activeViewID
        guard let target else { return }
        mutateForView(target) {
            $0.terminal = TerminalZone(shellSession: shell)
            $0.agentAreaRatio = persisted.companionRatio ?? 1.0
        }
    }

    private func clearLegacyFields() {
        persisted.splitTree = nil
        persisted.companionShell = nil
        persisted.companionRatio = nil
        persisted.showInspector = nil
        persisted.inspectorMode = nil
    }

    private func sanitizedTree(_ tree: PaneNode, live: Set<String>) -> PaneNode {
        var t: PaneNode? = tree
        for dead in tree.leaves where !live.contains(dead) {
            t = t?.removing(session: dead).tree ?? t
        }
        return t ?? tree
    }

    func sanitizeViews() {
        let live = Set(sessions.map(\.name))
        for (id, var v) in views {
            var emptied = false
            for dead in v.leaves where !live.contains(dead) {
                if v.removeLeaf(dead).emptied { emptied = true }
            }
            if emptied {
                if let shell = v.terminal?.shellSession { Task { await kill(shell) } }
                views[id] = nil
                continue
            }
            if let shell = v.terminal?.shellSession, !live.contains(shell) {
                v.terminal = TerminalZone(shellSession: nil)   // keep zone open, relink pending
            }
            views[id] = v
        }
        for name in Array(viewOfSession.keys) where views[viewOfSession[name]!] == nil {
            viewOfSession[name] = nil
        }
        for name in viewOfSession.keys where !(views[viewOfSession[name]!]?.leaves.contains(name) ?? false) {
            viewOfSession[name] = nil
        }
        for s in sessions where s.companionOf == nil && s.hidden != true
            && viewOfSession[s.name] == nil {
            ensureView(for: s.name)
        }
    }

    // MARK: - Terminal zone

    /// Toggle the active view's terminal zone (Command-P › Open Terminal).
    func toggleActiveTerminal() async {
        guard let id = activeViewID, let v = views[id] else { toast = "no session"; return }
        if v.terminal != nil { closeActiveTerminal(); return }
        mutateForView(id) { $0.terminal = TerminalZone(shellSession: nil) }
        await spawnShell(for: id)
    }

    /// Spawn a hidden shell at the project root for a view whose terminal zone
    /// is open but unlinked.
    func spawnShell(for viewID: ViewID) async {
        guard let v = views[viewID], v.terminal != nil, v.terminal?.shellSession == nil
        else { return }
        let anchorName = (focusedAgentPane.map { [$0] } ?? []) + v.leaves
        guard let anchor = anchorName.lazy.compactMap({ n in self.sessions.first { $0.name == n } }).first
        else { return }
        let root = projectRoot(sessionRoot(anchor))
        pendingShellForView = viewID
        do {
            _ = try await client.create(dir: root, agent: "sh", terminal: true, hidden: true)
        } catch {
            pendingShellForView = nil
            toast = errorText(error)
            mutateForView(viewID) { $0.terminal = nil }
        }
    }

    /// Relink surviving shells; respawn any whose daemon session is gone.
    func relinkOrRespawnShells() async {
        let live = Set(sessions.map(\.name))
        for (id, v) in views {
            guard v.terminal != nil else { continue }
            if let shell = v.terminal?.shellSession, live.contains(shell) {
                await attachPane(shell)
            } else {
                mutateForView(id) { $0.terminal?.shellSession = nil }
                await spawnShell(for: id)
            }
        }
    }
}
