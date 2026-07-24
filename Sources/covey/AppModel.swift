import AppKit
import Foundation
import Observation
import CoveyKit

/// ⌘1-5 zone targets (menu key equivalents — reachable from any focus).
public enum FocusZone: Equatable {
    case session, agent, note, issues, terminalSplit, trace
}

/// UI state machine. The daemon is the single source of truth about sessions:
/// actions call the IPC client and the model mutates only when the daemon's
/// events confirm the change. One instance owns the single `client.events`
/// consumer (the stream delivers each element to exactly one iterator).
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable {
        case newSession
        case recent
        case kill(String)
        case rename(String)
        case renameProject(String)
        case promote(String)
        case deleteBranch(String)
        case cleanup(String)
        case restart(String)
        case restartAll
        case themeRestart
        case addProject
    }

    public enum Focus { case sessions, terminal, inspector }

    public enum TerminalCommand: Equatable {
        case focus, blur, scrollPage(up: Bool), scrollToBottom
    }

    public private(set) var sessions: [Session] = []       // sorted by created
    public private(set) var statusByName: [String: Status] = [:]
    /// Model id of the last assistant message per claude session (daemon's
    /// transcript monitor); missing key = no badge on the card.
    public private(set) var modelByName: [String: String] = [:]
    public private(set) var selected: String?
    /// Terminal pane that owns the keyboard while focus == .terminal:
    /// the selected session or its companion shell.
    public private(set) var focusedPane: String?
    public var modal: Modal? {
        didSet {
            // A sheet lives in its own key window; its dismissal reshuffles
            // the main window's first responder. If the terminal zone owns
            // the keyboard, hand it back — after the dismissal settles.
            guard modal == nil, oldValue != nil, focus == .terminal else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modal == nil, self.focus == .terminal else { return }
                self.sendTerminalCommand(.focus)
            }
        }
    }
    @ObservationIgnored private var toastDismiss: Task<Void, Never>?
    /// How long a transient toast stays before auto-dismissing (test-tunable).
    @ObservationIgnored var toastDismissDelay: Duration = .seconds(4)
    public private(set) var toast: String? {
        didSet {
            // Transient confirmations/errors auto-dismiss so they don't hang
            // forever; status toasts shown while disconnected (e.g. "daemon
            // connection lost", which carries the Reconnect button) persist
            // until reconnect clears them.
            toastDismiss?.cancel()
            guard toast != nil, connected else { return }
            let delay = toastDismissDelay
            toastDismiss = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.toast = nil
            }
        }
    }
    public private(set) var connected = false
    public private(set) var themeRaw: String = "dark"
    public private(set) var splitPct: Int = 38
    public private(set) var usagePlacement: UsagePlacement = .right
    public private(set) var recents: [RecentSession] = []
    public private(set) var usage: Usage?
    public private(set) var plan: String?
    public private(set) var usageError: String?
    // Codex limits are consumed only in-module (TopBar) + @testable tests, so
    // these stay internal — their types (CodexRateLimitsSnapshot/State) are too.
    private(set) var codexUsage: CodexRateLimitsSnapshot?
    private(set) var codexPlan: String?
    private(set) var codexState: CodexServerState = .stopped
    public private(set) var order: [String] = []
    public private(set) var projectOrder: [String] = []
    public var filter: String = ""
    public private(set) var historyMode = false
    public private(set) var focus: Focus = .sessions
    public private(set) var showSessions = true
    public private(set) var showFooter = true
    public private(set) var showHeader = true
    public private(set) var showInspector = false
    public enum InspectorTab: Equatable { case note, issue }
    public private(set) var inspectorTab: InspectorTab = .note
    public private(set) var inspectorSplit = false
    /// The right drawer shows EITHER the Note/Issue inspector OR the agent
    /// trace — never both (there is no room for two drawers).
    public enum InspectorMode: Equatable { case notes, trace }
    public private(set) var inspectorMode: InspectorMode = .notes
    /// Agent trace for the selected session (streamed from the daemon).
    public private(set) var traceEvents: [TraceEvent] = []
    public private(set) var traceStoreBytes: Int = 0
    public private(set) var traceAgentFilter: TraceEvent.AgentRef?

    /// Trace rows narrowed to the selected agent (nil filter = all agents).
    public var visibleTraceEvents: [TraceEvent] {
        guard let f = traceAgentFilter else { return traceEvents }
        return traceEvents.filter { $0.agent == f }
    }
    public func setTraceAgentFilter(_ ref: TraceEvent.AgentRef?) { traceAgentFilter = ref }
    /// Transient: a pane sets it while its editor/field owns the keyboard
    /// (drives the INSERT/NORMAL badge).
    public var inspectorEditing = false
    /// Vim mode badge from the issue body editor ("NORMAL"/"INSERT"/...);
    /// nil when the editor is not mounted.
    public var inspectorVimBadge: String?
    /// Which screen the inspector's Issue tab shows; browser is home.
    public enum IssueScreen: Equatable { case browser, composer }
    public private(set) var issueScreen: IssueScreen = .browser
    /// Session name to prefill in the New Session sheet (set by issue's `s`).
    public private(set) var newSessionPrefillName: String?
    /// The issue browser's state machine (gh access injected here).
    public let issueBrowser: IssueBrowserModel
    /// Bumped by space g i; IssuePane focuses the title field on change.
    public private(set) var issueFocusTick = 0
    /// Bumped on entering the note zone; the note editor grabs the keys.
    public private(set) var noteFocusTick = 0
    public private(set) var sbWidth = 360
    public private(set) var vimMode = false
    /// The footer filter is showing (activated by `/` or ⌘F).
    public private(set) var filterActive = false
    private(set) var inputMode: InputMode = .normal
    /// Dir to prefill in the New Session sheet (set by `N`).
    public private(set) var newSessionPrefillDir: String?
    /// Issue number the pending New Session is being created for (issue's `s`);
    /// the sheet records the binding on the created session's name.
    public private(set) var newSessionPrefillIssue: Int?
    /// Branch to prefill (create-session-in-branch from an issue).
    public private(set) var newSessionPrefillBranch: String?
    public private(set) var notes: [String: String] = [:]
    public private(set) var projectNotes: [String: String] = [:]
    public private(set) var projectNames: [String: String] = [:]
    public private(set) var projects: [String] = []
    /// Selected empty-project ghost row; mutually exclusive with `selected`.
    public private(set) var selectedProjectRoot: String?

    /// Output sinks per session name. A terminal view mounts asynchronously
    /// after attach, so bytes (notably the attach backfill) can arrive before
    /// the sink exists — they buffer per name and flush on registration.
    private var outputSinks: [String: ([UInt8]) -> Void] = [:]
    private var outputBuffers: [String: [UInt8]] = [:]
    /// Focus/scroll command handlers per mounted terminal view.
    private var terminalCommands: [String: (TerminalCommand) -> Void] = [:]
    @ObservationIgnored
    private var terminalResizeOwnership = TerminalResizeOwnership()
    /// Names this client is attached to (selected + visible companion).
    private var attachedNames: Set<String> = []

    public func setTerminalSink(for name: String, _ sink: (([UInt8]) -> Void)?) {
        if let sink {
            outputSinks[name] = sink
            if let pending = outputBuffers.removeValue(forKey: name), !pending.isEmpty {
                sink(pending)
            }
        } else {
            outputSinks[name] = nil
        }
    }

    public func setTerminalCommandHandler(for name: String,
                                          _ handler: ((TerminalCommand) -> Void)?) {
        terminalCommands[name] = handler
    }

    /// Route a view command to the focused pane's terminal (fallback: selected).
    private func sendTerminalCommand(_ cmd: TerminalCommand) {
        let target = focusedPane ?? selected
        if let target { terminalCommands[target]?(cmd) }
    }

    private var client: IPCClient
    private let makeClient: () throws -> IPCClient
    private let store: StateStore
    private var persisted = PersistedState()   // last known full state (keeps schema-only fields)
    private var eventLoop: Task<Void, Never>?
    private let fetchAccount: () async -> Account
    private let usageInterval: TimeInterval
    private var usagePoller: Task<Void, Never>?
    @ObservationIgnored private var codexServer: CodexAppServer?

    public init(client: IPCClient,
                makeClient: @escaping () throws -> IPCClient,
                store: StateStore,
                fetchAccount: @escaping () async -> Account = { Account() },
                usageInterval: TimeInterval = 60) {
        // Created before any self-capturing closures below.
        issueBrowser = IssueBrowserModel(
            fetchIssues: { dir, state in await IssueService.list(dir: dir, state: state) },
            fetchLabels: { dir in await IssueService.labelList(dir: dir) },
            runMutation: { args, dir in await IssueService.mutate(args: args, dir: dir) })
        self.client = client
        self.makeClient = makeClient
        self.store = store
        self.fetchAccount = fetchAccount
        self.usageInterval = usageInterval
        issueBrowser.toast = { [weak self] msg in self?.showToast(msg) }
        issueBrowser.fetchBranches = { [weak self] dir in
            await self?.gitInfo(dir).branches ?? []
        }
    }

    public func start() async {
        persisted = store.load()
        themeRaw = persisted.theme ?? "dark"
        splitPct = persisted.splitPct ?? 38
        usagePlacement = persisted.usagePlacement.flatMap(UsagePlacement.init(rawValue:)) ?? .right
        recents = persisted.recents
        order = persisted.order
        projectOrder = persisted.projectOrder
        showSessions = persisted.showSessions ?? true
        showFooter = persisted.showFooter ?? true
        showHeader = persisted.showHeader ?? true
        showInspector = persisted.showInspector ?? false
        inspectorSplit = persisted.inspectorSplit ?? false
        inspectorMode = persisted.inspectorMode == "trace" ? .trace : .notes
        sbWidth = persisted.sbWidth ?? 360
        vimMode = persisted.vimMode ?? true
        notes = persisted.notes
        projectNotes = persisted.projectNotes
        projectNames = persisted.projectNames
        projects = persisted.projects ?? []
        do {
            let (list, statuses, lost, models) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            modelByName = models
            connected = true
            toast = nil
            if let lost, !lost.isEmpty {
                // Sessions a dead daemon lost: surface them as relaunchable
                // recents, oldest first so the newest ends on top.
                for s in lost.sorted(by: { $0.created < $1.created }) {
                    pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent,
                                                       resumeCmd: s.resumeCmd,
                                                       stoppedAt: Int64(Date().timeIntervalSince1970)))
                }
                persist()
                try? await client.clearLost()
            }
            // Land on the first session instead of a "select a session"
            // placeholder — saves the launch click.
            if selected == nil, let first = visibleSessionNames().first {
                await select(first)
            }
        } catch {
            connected = false
            toast = errorText(error)
            return
        }
        eventLoop?.cancel()
        // Inherits MainActor: apply() and the trailing mutations run on the actor.
        eventLoop = Task { [client] in
            for await event in client.events {
                self.apply(event)
            }
            self.connected = false
            self.toast = "daemon connection lost"
        }
        usagePoller?.cancel()
        usagePoller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickUsage()
                try? await Task.sleep(nanoseconds: UInt64(self.usageInterval * 1_000_000_000))
            }
        }
        startCodexServer()
    }

    public func select(_ name: String?) async {
        guard name != selected else { return }
        for n in attachedNames { try? await client.detach(name: n) }
        attachedNames = []
        outputBuffers = [:]        // drop any bytes buffered for old sessions
        selected = name
        if name != nil { selectedProjectRoot = nil }
        focusedPane = name
        historyMode = false
        if let name {
            await attachPane(name)
            if let comp = companion(of: name) { await attachPane(comp.name) }
        }
        if inspectorMode == .trace { await subscribeTrace() }
    }

    public func setInspectorMode(_ mode: InspectorMode) {
        inspectorMode = mode
        if mode == .trace { Task { await subscribeTrace() } }
        persist()
    }

    /// (Re)subscribe the selected session's trace: replace the buffer with the
    /// daemon's backlog, then live `traceAppended` events accumulate onto it.
    private func subscribeTrace() async {
        traceEvents = []; traceAgentFilter = nil
        guard let name = selected else { return }
        do {
            let out = try await client.traceSubscribe(name: name, sinceSeq: 0)
            traceEvents = out.events
            traceStoreBytes = out.storeBytes
            capTrace()
        } catch { toast = errorText(error) }
    }

    /// Bound the in-memory trace so a long-running session can't grow the render
    /// list without limit (older rows drop off the bottom of the stack).
    private func capTrace(_ maximum: Int = 1000) {
        if traceEvents.count > maximum {
            traceEvents.removeFirst(traceEvents.count - maximum)
        }
    }

    /// Names whose attach replay was already consumed by a mounted view. A
    /// SECOND mount for such a name is a structural remount (split toggle
    /// rebuilds TerminalPaneView's branch): the fresh emulator never saw the
    /// session's one-shot DECSETs, so it needs the attach replay again or
    /// wheel routing degrades to `.viewport` until an app restart.
    private var viewMountedSinceAttach: Set<String> = []

    private func attachPane(_ name: String) async {
        // Mark attached BEFORE the RPC: the daemon writes the backfill
        // output event ahead of the reply, so apply(.output) can run during
        // this await — a name not yet marked would drop its own backfill.
        attachedNames.insert(name)
        viewMountedSinceAttach.remove(name)
        do {
            try await client.attach(name: name, sinceSeq: 0)
        } catch {
            attachedNames.remove(name)
            toast = errorText(error)
        }
    }

    /// Called from makeNSView. The first mount after an attach just consumes
    /// the pending replay; any later mount re-requests it from the daemon.
    public func paneViewMounted(_ name: String) {
        guard attachedNames.contains(name) else { return }
        if viewMountedSinceAttach.contains(name) {
            Task {
                do { try await client.attach(name: name, sinceSeq: 0) }
                catch { toast = errorText(error) }
            }
        } else {
            viewMountedSinceAttach.insert(name)
        }
    }

    public func focusPane(_ name: String) {
        focusedPane = name
        setFocus(.terminal)
        terminalCommands[name]?(.focus)
    }

    public func create(dir: String, agent: String) async {
        do { _ = try await client.create(dir: dir, agent: agent) }
        catch { toast = errorText(error) }
    }

    public func kill(_ name: String, removeWorktree: Bool = false,
                     deleteBranch: Bool = false) async {
        do {
            try await client.kill(name: name,
                                  removeWorktree: removeWorktree ? true : nil,
                                  deleteBranch: deleteBranch ? true : nil)
        } catch { toast = errorText(error) }
    }

    /// Restart via the daemon; the error text doubles as the sheet's inline
    /// banner. `dir` overrides the respawn directory (return-to-root).
    @discardableResult
    public func restart(_ name: String, dir: String? = nil) async -> String? {
        do { try await client.restart(name: name, dir: dir); return nil }
        catch { let msg = errorText(error); toast = msg; return msg }
    }

    /// The `space a u` bulk restart: every session whose agent's first word is
    /// claude. Returns per-session error lines (empty = all good).
    public func restartAllClaude() async -> [String] {
        var errors: [String] = []
        for s in visibleSessions where s.agent.split(separator: " ").first == "claude" {
            if let err = await restart(s.name) { errors.append("\(s.name): \(err)") }
        }
        return errors
    }

    /// After a theme toggle: claude reads its palette once at startup, so
    /// live agents keep the old colors until restarted. Offers a restart of
    /// the idle ones; busy agents are only counted in a toast.
    public func offerThemeRestart() {
        let plan = themeRestartPlan(sessions: visibleSessions, statuses: statusByName)
        if !plan.idle.isEmpty {
            modal = .themeRestart
        } else if !plan.busy.isEmpty {
            toast = "\(plan.busy.count) agent(s) keep old theme — restart when idle (space s u)"
        }
    }

    /// Confirm handler of the theme-restart sheet: restarts every claude
    /// session still idle at confirm time (the plan is recomputed — some may
    /// have started working since the sheet opened). Returns error lines.
    public func restartIdleClaude() async -> [String] {
        let plan = themeRestartPlan(sessions: visibleSessions, statuses: statusByName)
        var errors: [String] = []
        for name in plan.idle {
            if let err = await restart(name) { errors.append("\(name): \(err)") }
        }
        return errors
    }

    public func gitInfo(_ dir: String) async
        -> (repoRoot: String?, currentBranch: String?, branches: [String],
            worktrees: [String: String]) {
        (try? await client.gitInfo(dir: dir)) ?? (nil, nil, [], [:])
    }

    /// The full-form create; errors surface as a toast AND are returned for
    /// the sheet's inline banner.
    @discardableResult
    public func createFull(name: String?, dir: String, agent: String,
                           terminal: Bool, worktree: WorktreeSpec?,
                           model: String?, effort: String?) async -> String? {
        do {
            let s = try await client.create(dir: dir, agent: agent, name: name,
                                            terminal: terminal ? true : nil,
                                            worktree: worktree, model: model,
                                            effort: effort)
            // Land in the fresh session, keyboard in its terminal.
            await select(s.name)
            setFocus(.terminal)
            return nil
        } catch {
            return errorText(error)
        }
    }

    public func rename(_ name: String, to newName: String) async {
        do { try await client.rename(name: name, newName: newName) }
        catch { toast = errorText(error); return }
        // Migrate name-keyed state so a rename doesn't orphan it.
        if var axes = persisted.splitAxes, let axis = axes.removeValue(forKey: name) {
            axes[newName] = axis
            persisted.splitAxes = axes
        }
        if var map = persisted.issueBySession, let issue = map.removeValue(forKey: name) {
            map[newName] = issue
            persisted.issueBySession = map
        }
        if let note = notes.removeValue(forKey: name) { notes[newName] = note }
        persist()
        if name == selected {
            selected = nil            // select() guard: force the re-attach chain
            await select(newName)
        }
    }

    public func sendInput(_ bytes: [UInt8], to name: String) async {
        try? await client.input(name: name, bytes: bytes)
    }

    @ObservationIgnored private var lastRefreshAt: [String: Date] = [:]
    @ObservationIgnored private var refreshTrailing: [String: Task<Void, Never>] = [:]

    /// SIGWINCH-kick the child so it fully repaints — wheel-scrolling a TUI
    /// leaves the alt buffer partially redrawn. Throttled (a live kick at most
    /// every 40 ms) plus a trailing kick so the frame after scrolling settles is
    /// clean.
    func requestTerminalRefresh(_ name: String) {
        let now = Date()
        if lastRefreshAt[name].map({ now.timeIntervalSince($0) >= 0.04 }) ?? true {
            lastRefreshAt[name] = now
            Task { [client] in try? await client.refresh(name: name) }
        }
        refreshTrailing[name]?.cancel()
        refreshTrailing[name] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastRefreshAt[name] = Date()
            try? await self.client.refresh(name: name)
        }
    }

    /// A claude agent pane. Its terminal suppresses mouse reporting
    /// (keyboard-first): a click only focuses/selects-text, never reaches
    /// Claude's mouse-interactive prompt to auto-pick an option.
    public func agentIsClaude(_ name: String) -> Bool {
        sessions.first { $0.name == name }?.agent.split(separator: " ").first == "claude"
    }

    func mountTerminalView(_ name: String) -> TerminalViewLease {
        terminalResizeOwnership.mount(session: name)
    }

    func unmountTerminalView(_ lease: TerminalViewLease) {
        terminalResizeOwnership.unmount(lease)
    }

    func isTerminalViewLeaseCurrent(_ lease: TerminalViewLease) -> Bool {
        terminalResizeOwnership.isCurrent(lease)
    }

    func resize(
        cols: UInt16,
        rows: UInt16,
        lease: TerminalViewLease
    ) async {
        guard isTerminalViewLeaseCurrent(lease) else { return }
        try? await client.resize(
            name: lease.session,
            cols: cols,
            rows: rows
        )
    }

    /// Sheets fire-and-forget outcomes (issue created after Esc-hide, …).
    public func showToast(_ message: String) { toast = message }

    public func reconnect() async {
        do {
            client = try makeClient()
            toast = nil
        } catch {
            toast = errorText(error)
            return
        }
        let previous = selected
        selected = nil                     // start() re-lists; drop stale selection
        await start()
        // Re-attach only if the session survived (a fresh daemon lost it — no
        // persistence yet — so don't attach a ghost and toast "not found").
        if let previous, sessions.contains(where: { $0.name == previous }) {
            await select(previous)
        }
    }

    public func setTheme(_ raw: String) {
        guard raw != themeRaw else { return }
        themeRaw = raw
        persist()
    }

    public func setSplitPct(_ pct: Int) {
        let clamped = min(80, max(15, pct))
        guard clamped != splitPct else { return }
        splitPct = clamped
        persist()
    }

    @discardableResult
    public func relaunchRecent(_ r: RecentSession, activate: Bool = true) async -> Bool {
        do {
            let s = try await client.create(dir: r.dir, agent: r.agent, name: r.name,
                                            resume: r.resumeCmd)
            if activate {
                await select(s.name)
                setFocus(.terminal)
            }
            return true
        } catch {
            toast = errorText(error)
            return false
        }
    }

    /// Sessions that get cards/numbers/counts — companions are invisible.
    public var visibleSessions: [Session] {
        sessions.filter { $0.companionOf == nil }
    }

    public func companion(of name: String) -> Session? {
        sessions.first { $0.companionOf == name }
    }

    public func splitAxis(for name: String) -> String {
        persisted.splitAxes?[name] ?? "v"
    }

    public var counts: (total: Int, running: Int, waiting: Int) {
        var r = 0, w = 0
        for s in visibleSessions {
            switch statusByName[s.name] {
            case .running: r += 1
            case .waiting: w += 1
            default: break
            }
        }
        return (visibleSessions.count, r, w)
    }

    /// Project groups (keyed by sessionRoot, so a worktree session sits with
    /// its repo) ordered by `projectOrder` (unknown roots appended by first
    /// appearance); within a group, sessions ordered by `order` (unknown by created).
    public func orderedSessions() -> [(dir: String, sessions: [Session])] {
        orderedDirs().map { dir in
            let inDir = visibleSessions.filter { sessionRoot($0) == dir }.sorted { a, b in
                let ia = order.firstIndex(of: a.name) ?? Int.max
                let ib = order.firstIndex(of: b.name) ?? Int.max
                if ia != ib { return ia < ib }
                // `created` has 1s resolution, so adjacent creates tie; break by
                // name to keep the order deterministic (Swift's sort is unstable).
                if a.created != b.created { return a.created < b.created }
                return a.name < b.name
            }
            return (dir, inDir)
        }
    }

    public func setFilter(_ s: String) { filter = s }
    /// Esc in the footer filter: clear and give the list back its keys.
    public func filterEscape() {
        filter = ""
        filterActive = false
    }

    /// Enter in the footer filter: keep the selection, drop the filter and
    /// jump straight into the selected session's terminal.
    public func filterCommit() {
        filter = ""
        filterActive = false
        if selected != nil {
            setFocus(.terminal)
            sendTerminalCommand(.focus)
        }
    }
    public func setHistoryMode(_ on: Bool) {
        guard historyMode != on else { return }
        historyMode = on
    }
    public func setFocus(_ f: Focus) { focus = f }

    public func moveSession(inDir dir: String, from: IndexSet, to: Int) {
        var names = (orderedSessions().first { $0.dir == dir }?.sessions.map(\.name)) ?? []
        names.move(fromOffsets: from, toOffset: to)
        // Rebuild the flat `order` across every dir in its current order.
        var newOrder: [String] = []
        for group in orderedSessions() {
            newOrder.append(contentsOf: group.dir == dir ? names : group.sessions.map(\.name))
        }
        order = newOrder
        persist()
    }

    public func moveProject(from: IndexSet, to: Int) {
        var dirs = orderedDirs()
        dirs.move(fromOffsets: from, toOffset: to)
        projectOrder = dirs
        persist()
    }

    public func setShowSessions(_ on: Bool) { showSessions = on; persist() }
    public func setShowFooter(_ on: Bool) { showFooter = on; persist() }
    public func setShowHeader(_ on: Bool) { showHeader = on; persist() }
    public func setShowInspector(_ on: Bool) { showInspector = on; persist() }
    public func setVimMode(_ on: Bool) { vimMode = on; persist() }

    public func setSbWidth(_ px: Int) {
        let clamped = min(600, max(240, px))
        guard clamped != sbWidth else { return }
        sbWidth = clamped
        persist()
    }

    private func orderedDirs() -> [String] {
        var seen = Set<String>(); var dirs: [String] = []
        let live = visibleSessions.map(sessionRoot)
        let known = Set(live).union(projects)
        for d in projectOrder where known.contains(d) {
            if seen.insert(d).inserted { dirs.append(d) }
        }
        for d in live where !seen.contains(d) {
            if seen.insert(d).inserted { dirs.append(d) }
        }
        for d in projects where !seen.contains(d) {
            if seen.insert(d).inserted { dirs.append(d) }
        }
        return dirs
    }

    /// Flat visible ordering: orderedSessions() narrowed by the fuzzy filter.
    public func visibleSessionNames() -> [String] {
        orderedSessions().flatMap { group in
            group.sessions.map(\.name).filter { fuzzyMatch(filter, $0) }
        }
    }

    /// A navigable sidebar row: a session card or an empty project's ghost row.
    public enum ListRow: Equatable {
        case session(String)
        case ghost(String)
    }

    /// Flat visible ordering including ghost rows — what j/k walks. Ghosts
    /// hide while the fuzzy filter is active (it matches session names only).
    public func visibleRows() -> [ListRow] {
        orderedSessions().flatMap { group -> [ListRow] in
            let names = group.sessions.map(\.name).filter { fuzzyMatch(filter, $0) }
            if !names.isEmpty { return names.map(ListRow.session) }
            if group.sessions.isEmpty, filter.isEmpty { return [.ghost(group.dir)] }
            return []
        }
    }

    /// Recents hidden while a live session reuses the name (Recent tab rule).
    public func visibleRecents() -> [RecentSession] {
        let active = Set(sessions.map(\.name))
        return recents.filter { !active.contains($0.name) }
    }

    public func clearNewSessionPrefill() {
        newSessionPrefillDir = nil
        newSessionPrefillName = nil
        newSessionPrefillIssue = nil
        newSessionPrefillBranch = nil
    }

    /// Binds a created session's name to an issue number so the issue browser
    /// can find it even after a rename strips the "#N" from the name.
    public func bindIssue(_ number: Int, toSession name: String) {
        var map = persisted.issueBySession ?? [:]
        map[name] = number
        persisted.issueBySession = map
        persist()
    }

    /// The issue a session is bound to, if any (stored binding only).
    public func issueNumber(forSession name: String) -> Int? {
        persisted.issueBySession?[name]
    }

    public func setIssueScreen(_ s: IssueScreen) { issueScreen = s }

    /// Prefills the New Session sheet from an issue (issue browser's `s`).
    /// No-op without a selected session's root — nothing to base the
    /// worktree dir on.
    public func newSessionFromIssue(number: Int, title: String, branch: String? = nil) {
        guard let root = sessionRootOfSelected() else { return }
        newSessionPrefillDir = root
        newSessionPrefillName = sessionNameForIssue(number: number, title: title)
        newSessionPrefillIssue = number
        newSessionPrefillBranch = branch
        modal = .newSession
    }

    public func setNote(session: String, text: String) {
        if text.isEmpty { notes[session] = nil } else { notes[session] = text }
        persist()
    }

    public func setProjectNote(dir: String, text: String) {
        if text.isEmpty { projectNotes[dir] = nil } else { projectNotes[dir] = text }
        persist()
    }

    public func setProjectName(dir: String, name: String) {
        if name.isEmpty { projectNames[dir] = nil } else { projectNames[dir] = name }
        persist()
    }

    public func displayName(forDir dir: String) -> String {
        projectNames[dir] ?? projectDefaultName(dir)
    }

    func apply(_ action: KeyAction) {
        switch action {
        case .selectNext: step(by: 1)
        case .selectPrev: step(by: -1)
        case .selectFirst: jump(to: 0)
        case .selectByNumber(let n):
            jump(to: n - 1)
            inputMode = .normal
        case .enterTerminal:
            if selected != nil {
                setFocus(.terminal)
                sendTerminalCommand(.focus)
            }
        case .exitTerminal:
            setFocus(.sessions)
            sendTerminalCommand(.blur)
        case .newSession(let prefill):
            newSessionPrefillDir = prefill ? inspectorRoot : nil
            modal = .newSession
        case .openRecent:
            inputMode = .normal
            modal = .recent
        case .killSelected:
            if let selected { modal = .kill(selected) }
        case .renameSelected:
            inputMode = .normal
            if let selected { modal = .rename(selected) }
        case .startFilter:
            filterActive = true
        case .openLeader:
            inputMode = .leader(.root)
        case .leaderDescend(let menu):
            inputMode = .leader(menu)
        case .leaderBack:
            inputMode = .leader(.root)
        case .closeOverlay:
            inputMode = .normal
        case .enterSelectMode:
            inputMode = .selectSession
        case .resizeSplit(let delta):
            setSplitPct(splitPct + delta)
        case .moveSelected(let up):
            moveSelectedSession(up: up)
        case .scrollTerminalPage(let up):
            sendTerminalCommand(.scrollPage(up: up))
        case .scrollTerminalToBottom:
            sendTerminalCommand(.scrollToBottom)
        case .showHelp:
            inputMode = .help
        case .openProjectNote:
            inputMode = .normal
            guard inspectorRoot != nil else { toast = "no project"; return }
            if !showInspector { setShowInspector(true) }
            setFocus(.inspector)
            selectInspectorTab(.note)
        case .renameProject:
            inputMode = .normal
            if let root = inspectorRoot { modal = .renameProject(root) }
        case .sendShiftTab:
            guard let selected else { return }
            Task { try? await client.input(name: selected, bytes: [0x1b, 0x5b, 0x5a]) }
        case .restartSelected:
            inputMode = .normal
            if let selected { modal = .restart(selected) }
        case .restartAllPrompt:
            inputMode = .normal
            modal = .restartAll
        case .toggleTheme:
            inputMode = .normal
            setTheme(themeRaw == "dark" ? "light" : "dark")
            offerThemeRestart()
        case .returnToRoot:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            guard isReturnable(s), let root = s.worktreeRepo else {
                toast = "worktree still alive"; return
            }
            if s.agent.split(separator: " ").first == "claude" {
                // Same pipeline as a plain restart, but respawned in the root.
                Task { await restart(s.name, dir: root) }
            } else {
                // A live shell just cd's back (port of the TUI behavior).
                let cmd = "cd \(shellSingleQuote(root))\n"
                Task { try? await client.input(name: s.name, bytes: Array(cmd.utf8)) }
            }
        case .promoteSelected:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.worktreeRepo == nil { toast = "not a worktree session"; return }
            modal = .promote(s.name)
        case .deleteBranchSelected:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.worktreeRepo != nil { toast = "cannot delete: worktree session"; return }
            guard let branch = s.git?.branch else { toast = "no git info"; return }
            if protectedBranches.contains(branch) {
                toast = "branch '\(branch)' is protected"
                return
            }
            modal = .deleteBranch(s.name)
        case .cleanupBranches:
            inputMode = .normal
            guard let s = selectedSession() else { return }
            if s.git == nil { toast = "not a git repo"; return }
            modal = .cleanup(s.dir)
        case .inspectorPaneSwap:
            selectInspectorTab(inspectorTab == .note ? .issue : .note)
        case .inspectorSplitToggle:
            inspectorSplit.toggle()
            persist()
        case .toggleSessionsPanel:
            inputMode = .normal
            setShowSessions(!showSessions)
        case .toggleInspectorPanel:
            inputMode = .normal
            if showInspector, focus == .inspector { setFocus(.sessions) }
            setShowInspector(!showInspector)
        case .toggleTracePanel:
            inputMode = .normal
            if showInspector, inspectorMode == .trace {
                // Trace is showing → close the drawer and return it to notes so
                // `space u i` opens the note/issue inspector as usual.
                if focus == .inspector { setFocus(.sessions) }
                setInspectorMode(.notes)
                setShowInspector(false)
            } else {
                if !showInspector { setShowInspector(true) }
                sendTerminalCommand(.blur)
                setFocus(.inspector)
                setInspectorMode(.trace)
            }
        case .toggleFooterPanel:
            inputMode = .normal
            setShowFooter(!showFooter)
        case .toggleHeaderPanel:
            inputMode = .normal
            setShowHeader(!showHeader)
        case .cycleUsagePlacement:
            inputMode = .normal
            usagePlacement = usagePlacement.next
            persist()
        case .createIssue:
            inputMode = .normal
            guard inspectorRoot != nil else { toast = "no project"; return }
            if let s = selectedSession(), s.git == nil { toast = "not a git repo"; return }
            if !showInspector { setShowInspector(true) }
            inspectorTab = .issue
            issueScreen = .composer
            setFocus(.inspector)
            Task { @MainActor in self.issueFocusTick += 1 }
        case .openIssueList:
            inputMode = .normal
            guard let s = selectedSession() else { toast = "no session"; return }
            if s.git == nil { toast = "not a git repo"; return }
            if !showInspector { setShowInspector(true) }
            issueScreen = .browser
            issueBrowser.screen = .list
            setFocus(.inspector)
            selectInspectorTab(.issue)
            // The pane self-opens via its root/tick .onChange handlers —
            // opening here too would double the gh fetch.
        case .splitVertical: openSplit(axis: "v")
        case .splitHorizontal: openSplit(axis: "h")
        case .splitClose:
            inputMode = .normal
            guard let comp = selected.flatMap({ companion(of: $0) }) else {
                toast = "no split"; return
            }
            Task { await kill(comp.name) }
        case .splitFocusToggle:
            guard let selected, let comp = companion(of: selected) else { return }
            focusPane(focusedPane == comp.name ? selected : comp.name)
        case .cycleFocus(let forward):
            cycleFocus(forward: forward)
        case .addProject:
            inputMode = .normal
            modal = .addProject
        case .removeProject:
            inputMode = .normal
            guard let root = inspectorRoot else { toast = "no project"; return }
            removeProject(root)
        }
    }

    /// ⌃h/⌃l: walk the focus zones in order — session list, agent pane,
    /// companion shell pane (when split), inspector note, inspector issue
    /// (when the drawer is shown) — wrapping.
    /// Direct zone jump for the View-menu ⌘1-5 items. Guards toast instead
    /// of mutating anything (spec: no auto-show inspector, no auto-split).
    public func focusZone(_ zone: FocusZone) {
        switch zone {
        case .session:
            sendTerminalCommand(.blur)
            setFocus(.sessions)
        case .agent:
            guard let selected else { toast = "no session"; return }
            focusPane(selected)
        case .note:
            guard showInspector else { toast = "inspector hidden — space u i"; return }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            selectInspectorTab(.note)
        case .issues:
            guard showInspector else { toast = "inspector hidden — space u i"; return }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            selectInspectorTab(.issue)
        case .terminalSplit:
            guard let selected, let comp = companion(of: selected) else {
                toast = "no split — space t v / h"; return
            }
            focusPane(comp.name)
        case .trace:
            guard showInspector else { toast = "inspector hidden — space u i"; return }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            setInspectorMode(.trace)
        }
    }

    private func cycleFocus(forward: Bool) {
        var zones: [(id: String, activate: () -> Void)] = [
            ("sessions", { self.sendTerminalCommand(.blur); self.setFocus(.sessions) })
        ]
        if let selected {
            zones.append(("pane:\(selected)", { self.focusPane(selected) }))
            if let comp = companion(of: selected) {
                zones.append(("pane:\(comp.name)", { self.focusPane(comp.name) }))
            }
        }
        if showInspector {
            zones.append(("inspector:note", {
                self.sendTerminalCommand(.blur)
                self.setFocus(.inspector)
                self.selectInspectorTab(.note)
            }))
            zones.append(("inspector:issue", {
                self.sendTerminalCommand(.blur)
                self.setFocus(.inspector)
                self.selectInspectorTab(.issue)
            }))
        }
        let currentID: String
        switch focus {
        case .sessions: currentID = "sessions"
        case .inspector:
            currentID = inspectorTab == .note ? "inspector:note" : "inspector:issue"
        case .terminal: currentID = "pane:\(focusedPane ?? selected ?? "")"
        }
        let idx = zones.firstIndex { $0.id == currentID } ?? 0
        let next = (idx + (forward ? 1 : -1) + zones.count) % zones.count
        zones[next].activate()
    }

    private func openSplit(axis: String) {
        inputMode = .normal
        guard let s = selectedSession() else { toast = "no session"; return }
        if let comp = companion(of: s.name) {
            focusPane(comp.name)
            return
        }
        var axes = persisted.splitAxes ?? [:]
        axes[s.name] = axis
        persisted.splitAxes = axes
        persist()
        Task {
            do {
                _ = try await client.create(dir: s.dir, agent: "sh", terminal: true,
                                            companionOf: s.name)
            } catch { toast = errorText(error) }
        }
    }

    private func selectedSession() -> Session? {
        sessions.first { $0.name == selected }
    }

    /// The root the inspector panes (note/issue) operate on: an explicitly
    /// selected project wins, else the selected session's project root.
    public var inspectorRoot: String? {
        selectedProjectRoot ?? selectedSession().map(sessionRoot)
    }

    /// The repo root a new-session-from-issue action targets. The issue browser
    /// lives in the inspector, so it shares `inspectorRoot`.
    public func sessionRootOfSelected() -> String? { inspectorRoot }

    /// The working directory the inspector's issue browser and composer run
    /// gh/git in: the selected session's dir (a worktree when it has one), else
    /// the project root — so an explicitly selected project with no sessions
    /// still lists issues instead of stranding the prior project's list.
    public var inspectorDir: String? {
        selectedSession()?.dir ?? inspectorRoot
    }

    public func selectProject(_ root: String) async {
        await select(nil)
        // Re-check after the await: a concurrent removeProject must not let a
        // stale deferred selection resurrect an unregistered project.
        guard projects.contains(root) else { return }
        selectedProjectRoot = root
    }

    public func addProject(_ dir: String) {
        let root = projectRoot(dir)
        if !projects.contains(root) {
            projects.append(root)
            persist()
        }
        Task { await selectProject(root) }
    }

    public func removeProject(_ root: String) {
        guard projects.contains(root) else { toast = "project not registered"; return }
        projects.removeAll { $0 == root }
        if selectedProjectRoot == root { selectedProjectRoot = nil }
        persist()
        toast = "project removed"
    }

    public func selectInspectorTab(_ tab: InspectorTab) {
        inspectorTab = tab
        // Choosing a Note/Issue tab returns the drawer from the trace back to
        // the notes view (they never share the width).
        if inspectorMode != .notes { inspectorMode = .notes; persist() }
        // Both zones are always "in the editor": hand the keyboard over at
        // once (the zone chords escape the fields via the key monitor).
        // The bump is deferred by one runloop turn: a freshly mounted view
        // (e.g. IssuePane inserted this same transaction) never sees an
        // .onChange fire for a tick bump that lands in the same SwiftUI
        // transaction as its own insertion — it wasn't subscribed yet.
        // Deferring via Task guarantees the view is mounted first.
        Task { @MainActor in
            if tab == .issue { self.issueFocusTick += 1 } else { self.noteFocusTick += 1 }
        }
    }

    // MARK: - issue drafts (persisted per project root)

    public func issueDraft(forRoot root: String) -> IssueDraft {
        persisted.issueDrafts?[root] ?? IssueDraft()
    }

    public func setIssueDraft(_ draft: IssueDraft, forRoot root: String) {
        var drafts = persisted.issueDrafts ?? [:]
        drafts[root] = draft
        persisted.issueDrafts = drafts
        persist()
    }

    public func clearIssueDraft(forRoot root: String) {
        persisted.issueDrafts?[root] = nil
        persist()
    }

    // MARK: - git action passthroughs (errors surface inline in the sheets)

    public func promote(name: String) async -> String? {
        do { try await client.promote(name: name); return nil }
        catch { return errorText(error) }
    }

    public func deleteBranch(dir: String, branch: String) async -> String? {
        do { try await client.deleteBranch(dir: dir, branch: branch); return nil }
        catch { return errorText(error) }
    }

    public func mergedBranches(dir: String) async -> [String] {
        (try? await client.mergedBranches(dir: dir)) ?? []
    }

    /// Whether the session's worktree branch is safe to delete: `(dirty,
    /// merged)`. nil when the daemon can't answer (session gone / not a
    /// worktree) — the caller then keeps the delete toggle disabled.
    public func branchStatus(name: String) async -> (dirty: Bool, merged: Bool)? {
        try? await client.branchStatus(name: name)
    }

    public func cleanupBranches(dir: String, branches: [String]) async -> String? {
        do { try await client.cleanupBranches(dir: dir, branches: branches); return nil }
        catch { return errorText(error) }
    }

    private func rowIsCurrent(_ row: ListRow) -> Bool {
        switch row {
        case .session(let name): return name == selected
        case .ghost(let root): return selected == nil && root == selectedProjectRoot
        }
    }

    private func activate(_ row: ListRow) {
        switch row {
        case .session(let name): Task { await select(name) }
        case .ghost(let root): Task { await selectProject(root) }
        }
    }

    private func step(by delta: Int) {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        let cur = rows.firstIndex(where: rowIsCurrent) ?? -1
        activate(rows[min(rows.count - 1, max(0, cur + delta))])
    }

    private func jump(to index: Int) {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        activate(rows[min(rows.count - 1, max(0, index))])
    }

    /// Keyboard reorder within the selected session's project group.
    private func moveSelectedSession(up: Bool) {
        guard let selected else { return }
        guard let group = orderedSessions().first(where: { g in
            g.sessions.contains { $0.name == selected }
        }) else { return }
        let names = group.sessions.map(\.name)
        guard let idx = names.firstIndex(of: selected) else { return }
        guard up ? idx > 0 : idx < names.count - 1 else { return }
        let to = up ? idx - 1 : idx + 2   // IndexSet move semantics
        moveSession(inDir: group.dir, from: IndexSet(integer: idx), to: max(0, to))
    }

    // MARK: - private

    private func persist() {
        persisted.theme = themeRaw
        persisted.splitPct = splitPct
        persisted.usagePlacement = usagePlacement.rawValue
        persisted.recents = recents
        persisted.order = order
        persisted.projectOrder = projectOrder
        persisted.showSessions = showSessions
        persisted.showFooter = showFooter
        persisted.showHeader = showHeader
        persisted.showInspector = showInspector
        persisted.inspectorSplit = inspectorSplit
        persisted.inspectorMode = inspectorMode == .trace ? "trace" : "notes"
        persisted.sbWidth = sbWidth
        persisted.vimMode = vimMode
        persisted.notes = notes
        persisted.projectNotes = projectNotes
        persisted.projectNames = projectNames
        persisted.projects = projects
        store.save(persisted)
    }

    private func tickUsage() async {
        let acc = await fetchAccount()
        usage = acc.usage
        plan = acc.plan
        usageError = acc.usageError
        // Failed fetch (nil usage) must not touch alert markers: the
        // current window's dedup survives network gaps.
        guard let usage = acc.usage else { return }
        let old = persisted.usageNotified ?? [:]
        // Sonnet's 7d window is deliberately absent: chip-only, no alerts.
        let (alerts, marks) = limitAlerts(
            agent: "Claude",
            windows: [("5h", usage.fiveHour), ("7d", usage.sevenDay)],
            notified: old, now: Date())
        for alert in alerts { Notifier.post(alert) }
        if marks != old {
            persisted.usageNotified = marks
            persist()
        }
    }

    /// Spawn codex app-server if the binary resolves; wire snapshots/state in.
    /// No binary → stays `.stopped`, chip empty. Passive-only.
    private func startCodexServer() {
        guard codexServer == nil, let path = resolveCodexPath() else { return }
        let server = CodexAppServer()
        server.onState = { [weak self] state in self?.setCodexState(state) }
        server.onRateLimits = { [weak self] snap in self?.ingestCodexRateLimits(snap) }
        codexServer = server
        server.start(codexPath: path)
    }

    func setCodexState(_ state: CodexServerState) {
        codexState = state
        if case .active(let acc) = state {
            codexPlan = codexPlanLabel(acc.planType)
        } else {
            codexPlan = nil
            codexUsage = nil          // no chip when not active
        }
    }

    /// Merge a (possibly partial) Codex snapshot into the live one, then run
    /// the same 80%-alert machinery as Claude under the "codex" marker prefix.
    func ingestCodexRateLimits(_ update: CodexRateLimitsSnapshot, now: Date = Date()) {
        codexUsage = mergeCodex(into: codexUsage, update: update)
        guard let usage = codexUsage else { return }
        let old = persisted.usageNotified ?? [:]
        let windows: [(key: String, window: UsageWindow?)] =
            usage.windows.map { ($0.label, $0.window) }
        let (alerts, marks) = limitAlerts(agent: "Codex", windows: windows,
                                          notified: old, now: now)
        for alert in alerts { Notifier.post(alert) }
        if marks != old {
            persisted.usageNotified = marks
            persist()
        }
    }

    /// App teardown: terminate the codex subprocess.
    func stopCodexServer() {
        codexServer?.stop()
        codexServer = nil
    }

    private func apply(_ event: DaemonEvent) {
        switch event {
        case let .sessionAdded(session):
            sessions.removeAll { $0.name == session.name }
            sessions.append(session)
            sessions.sort { $0.created < $1.created }
            // A companion born for the selected session: show it and hand it
            // the keyboard (space t v flow).
            if session.companionOf == selected {
                Task {
                    await attachPane(session.name)
                    focusPane(session.name)
                }
            }
        case .sessionRemoved(let name):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            modelByName[name] = nil
            dropPaneState(name)
            if selected == name { selected = nil }
        case .exited(let name, _):
            // Companions never become recents — a dead shell is not resumable.
            if let s = sessions.first(where: { $0.name == name }), s.companionOf == nil {
                pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent,
                                                   resumeCmd: s.resumeCmd,
                                                   stoppedAt: Int64(Date().timeIntervalSince1970),
                                                   branch: s.git?.branch))
                persist()
            }
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            modelByName[name] = nil
            dropPaneState(name)
            if selected == name { selected = nil }
        case let .statusChanged(name, status):
            statusByName[name] = status
        case let .modelChanged(name, model):
            modelByName[name] = model
        case let .gitChanged(name, git):
            if let i = sessions.firstIndex(where: { $0.name == name }) {
                sessions[i].git = git
            }
        case let .output(name, _, bytesB64):
            guard attachedNames.contains(name),
                  let data = Data(base64Encoded: bytesB64) else { return }
            let bytes = [UInt8](data)
            if let sink = outputSinks[name] {
                sink(bytes)
            } else {
                // flushed when the view mounts
                outputBuffers[name, default: []].append(contentsOf: bytes)
            }
        case let .traceAppended(name, events):
            guard name == selected, inspectorMode == .trace else { return }
            traceEvents.append(contentsOf: events)
            capTrace()
        case let .traceStoreBytes(bytes):
            traceStoreBytes = bytes
        }
    }

    /// Forget a dead pane's view plumbing; pane focus falls back to selected.
    private func dropPaneState(_ name: String) {
        outputSinks[name] = nil
        outputBuffers[name] = nil
        terminalCommands[name] = nil
        attachedNames.remove(name)
        viewMountedSinceAttach.remove(name)
        if focusedPane == name { focusedPane = selected }
    }

    private func errorText(_ error: Error) -> String {
        if case let IPCClientError.daemonError(code, message) = error {
            return "\(code): \(message)"
        }
        return "\(error)"
    }
}
