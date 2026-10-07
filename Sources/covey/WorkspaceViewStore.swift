import Foundation
import CoveyKit

/// Workspace Views on `AppModel`: the `views` / `viewOfSession` maps live on
/// `AppModel` itself (an `@Observable` class needs its stored properties there);
/// everything that reads or mutates them lives here.
extension AppModel {
    // MARK: - Lookups

    var activeViewID: ViewID? { selected.flatMap { viewOfSession[$0] } }
    var activeView: WorkspaceView? { activeViewID.flatMap { views[$0] } }
    /// The active view's terminal shell session, if the zone is open and linked.
    var activeShell: String? { activeView?.terminal?.shellSession }

    func viewForSession(_ name: String) -> WorkspaceView? {
        viewOfSession[name].flatMap { views[$0] }
    }

    // MARK: - Mutation

    /// Mutate the active view in place and persist.
    func mutateActiveView(_ body: (inout WorkspaceView) -> Void) {
        guard let id = activeViewID else { return }
        mutateForView(id, body)
    }

    /// Mutate a view by id in place. Persists unless `persist` is false (callers
    /// doing several map edits at once pass false and persist once at the end).
    func mutateForView(_ id: ViewID, persist: Bool = true, _ body: (inout WorkspaceView) -> Void) {
        guard var v = views[id] else { return }
        body(&v)
        views[id] = v
        if persist { persistWorkspaceViews() }
    }

    /// New standalone single-leaf view for a session that has none.
    func ensureView(for session: String) {
        guard viewOfSession[session] == nil else { return }
        let id = newViewID()
        views[id] = .single(session, id: id)
        viewOfSession[session] = id
    }

    /// Pull one leaf out of its view: prune the tree, clear the `viewOfSession`
    /// entry, and delete an emptied view. Returns the focus successor within a
    /// surviving multi-leaf view and the shell that now needs killing (the
    /// emptied view's, if any). Does not persist — the caller does.
    func detachLeaf(_ name: String) -> (successor: String?, shellToKill: String?) {
        guard let id = viewOfSession[name], var v = views[id] else { return (nil, nil) }
        let r = v.removeLeaf(name)
        viewOfSession[name] = nil
        if r.emptied {
            views[id] = nil
            return (nil, v.terminal?.shellSession)
        }
        views[id] = v
        return (r.successor, nil)
    }

    /// A session left its view for a split-merge (it stays alive; the caller
    /// re-maps it). Deletes an emptied source view and kills its shell.
    func dropView(of session: String) async {
        let d = detachLeaf(session)
        if let shell = d.shellToKill { await kill(shell) }
        persistWorkspaceViews()
    }

    /// A session vanished (kill / `.exited`). Returns the focus successor within
    /// a surviving multi-leaf view.
    @discardableResult
    func removeSessionFromView(_ name: String) -> String? {
        let d = detachLeaf(name)
        if let shell = d.shellToKill { Task { await kill(shell) } }
        persistWorkspaceViews()
        return d.successor
    }

    /// Rename a leaf: rewrite the tree and move the `viewOfSession` key. Does not
    /// persist — the rename flow's `persist()` covers workspace views too.
    func renameSessionInView(_ old: String, to new: String) {
        guard let id = viewOfSession[old] else { return }
        mutateForView(id, persist: false) { $0.renameLeaf(old, to: new) }
        viewOfSession[old] = nil
        viewOfSession[new] = id
    }

    /// Close the active view's terminal zone and kill its shell. The view lives;
    /// if focus was on the shell it falls back to an agent pane.
    func closeActiveTerminal() {
        guard let id = activeViewID, let v = views[id], v.terminal != nil else { return }
        let shell = v.terminal?.shellSession
        let refocus = focusedPane == shell
        let agent = lastFocusedAgent ?? v.leaves.first
        mutateForView(id) { $0.terminal = nil }
        if let shell { Task { await kill(shell) } }
        if refocus, let agent { focusPane(agent) }
    }

    /// Copy the view maps into the persisted struct (id-sorted for stable JSON).
    /// Does not write to disk.
    func snapshotWorkspaceViews() {
        persisted.workspaceViews = views.values.sorted { $0.id < $1.id }.map(\.persisted)
        persisted.viewOfSession = viewOfSession
    }

    func persistWorkspaceViews() {
        snapshotWorkspaceViews()
        store.save(persisted)
    }

    // MARK: - Startup: load / migrate / sanitize

    /// Load persisted views, or migrate the legacy layout on first run.
    /// `legacyShell` is the companion shell name that `restoreLegacySplitAxes`
    /// kept from an even older `splitAxes` payload, if any.
    func loadOrMigrateViews(legacyShell: String? = nil) {
        if let pv = persisted.workspaceViews {
            for p in pv {
                let v = WorkspaceView(persisted: p)
                views[v.id] = v
                for leaf in v.leaves { viewOfSession[leaf] = v.id }
            }
        } else {
            migrateLegacyLayout(shell: legacyShell ?? persisted.companionShell)
        }
        sanitizeViews()
        persistWorkspaceViews()
    }

    private func migrateLegacyLayout(shell: String?) {
        let live = Set(sessions.filter { $0.companionOf == nil && $0.hidden != true }.map(\.name))
        for name in live { ensureView(for: name) }

        let legacyTree = persisted.splitTree.map(PaneNode.init(persisted:))
        let liveLeaves = legacyTree?.leaves.filter { live.contains($0) } ?? []
        let shellIsLive = shell.map { s in sessions.contains { $0.name == s } } ?? false

        if let legacyTree, liveLeaves.count >= 2 {
            // Merge the legacy tree's leaves into one view (sanitizeViews prunes
            // any dead leaf afterwards).
            let id = newViewID()
            for leaf in liveLeaves {
                if let old = viewOfSession[leaf], old != id { views[old] = nil }
                viewOfSession[leaf] = id
            }
            views[id] = WorkspaceView(
                id: id, agentTree: legacyTree,
                terminal: shellIsLive ? TerminalZone(shellSession: shell) : nil,
                inspector: persisted.showInspector == true
                    ? InspectorZone(persistedString: persisted.inspectorMode ?? "issues") : .hidden,
                agentAreaRatio: persisted.companionRatio)
        } else if shellIsLive {
            // Old single-pane + shell layout: attach the shell to its anchor's view.
            let parent = shell.flatMap { s in sessions.first { $0.name == s }?.companionOf }
            if let target = parent.flatMap({ viewOfSession[$0] }) ?? activeViewID {
                mutateForView(target, persist: false) {
                    $0.terminal = TerminalZone(shellSession: shell)
                    $0.agentAreaRatio = persisted.companionRatio
                }
            }
        }
        persisted.splitTree = nil
        persisted.companionShell = nil
        persisted.companionRatio = nil
        persisted.showInspector = nil
        persisted.inspectorMode = nil
    }

    func sanitizeViews() {
        let live = Set(sessions.map(\.name))
        for (id, initial) in views {
            var v = initial
            var emptied = false
            for dead in v.leaves where !live.contains(dead) {
                emptied = emptied || v.removeLeaf(dead).emptied
            }
            if emptied {
                if let shell = v.terminal?.shellSession { Task { await kill(shell) } }
                views[id] = nil
                continue
            }
            if let shell = v.terminal?.shellSession, !live.contains(shell) {
                v.terminal = TerminalZone(shellSession: nil)   // zone open, relink pending
            }
            views[id] = v
        }
        // `viewOfSession` must map exactly the leaves of existing views.
        for name in Array(viewOfSession.keys)
        where !(views[viewOfSession[name]!]?.leaves.contains(name) ?? false) {
            viewOfSession[name] = nil
        }
        for s in sessions where s.companionOf == nil && s.hidden != true
            && viewOfSession[s.name] == nil {
            ensureView(for: s.name)
        }
    }

    // MARK: - Terminal zone

    /// Toggle the active view's terminal zone (⌘T right column, ⌘⇧T bottom
    /// band). Open at the requested axis; already open at it → close; open at
    /// the other axis → rotate in place (the shell session survives).
    func toggleActiveTerminal(axis: PaneAxis = .vertical) async {
        guard let id = activeViewID, let v = views[id] else { toast = "no session"; return }
        if let zone = v.terminal {
            if zone.axis == axis { closeActiveTerminal(); return }
            mutateForView(id) { $0.terminal?.axis = axis }
            if let shell = zone.shellSession { focusPane(shell) }
            return
        }
        mutateForView(id) { $0.terminal = TerminalZone(shellSession: nil, axis: axis) }
        await spawnShell(for: id)
        if let shell = views[id]?.terminal?.shellSession { focusPane(shell) }
    }

    /// Spawn a hidden shell at the anchor agent's cwd (its worktree when it has
    /// one — where the agent works, not the repo root) for a view whose
    /// terminal zone is open but unlinked. Links from the create response — no
    /// shared pending slot, so relinking several views in a row is race-free.
    func spawnShell(for viewID: ViewID) async {
        guard let v = views[viewID], v.terminal != nil, v.terminal?.shellSession == nil
        else { return }
        let candidates = (focusedAgentPane.map { [$0] } ?? []) + v.leaves
        guard let anchor = candidates.lazy
            .compactMap({ n in self.sessions.first { $0.name == n } }).first
        else { return }
        do {
            let shell = try await client.create(dir: anchor.cwd, agent: "sh",
                                                terminal: true, hidden: true)
            guard views[viewID]?.terminal != nil else {   // view closed while awaiting
                await kill(shell.name); return
            }
            mutateForView(viewID) { $0.terminal?.shellSession = shell.name }
            await attachPane(shell.name)
        } catch {
            toast = errorText(error)
            mutateForView(viewID) { $0.terminal = nil }
        }
    }

    /// Relink surviving shells; respawn any whose daemon session is gone.
    /// Fired off the main `start()` path so the window paints first.
    func relinkOrRespawnShells() async {
        let live = Set(sessions.map(\.name))
        await withTaskGroup(of: Void.self) { group in
            for (id, v) in views where v.terminal != nil {
                group.addTask { @MainActor in
                    if let shell = v.terminal?.shellSession, live.contains(shell) {
                        await self.attachPane(shell)
                    } else {
                        self.mutateForView(id) { $0.terminal?.shellSession = nil }
                        await self.spawnShell(for: id)
                    }
                }
            }
        }
    }
}
