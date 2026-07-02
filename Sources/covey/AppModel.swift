import Foundation
import Observation
import CoveyKit

/// UI state machine. The daemon is the single source of truth about sessions:
/// actions call the IPC client and the model mutates only when the daemon's
/// events confirm the change. One instance owns the single `client.events`
/// consumer (the stream delivers each element to exactly one iterator).
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable {
        case newSession
        case kill(String)
        case rename(String)
    }

    public enum Focus { case sessions, terminal, inspector }

    public enum ListTab: Equatable { case active, recent }

    public enum TerminalCommand: Equatable {
        case focus, blur, scrollPage(up: Bool), scrollToBottom
    }

    public private(set) var sessions: [Session] = []       // sorted by created
    public private(set) var statusByName: [String: Status] = [:]
    public private(set) var selected: String?
    public var modal: Modal?
    public private(set) var toast: String?
    public private(set) var connected = false
    public private(set) var themeRaw: String = "dark"
    public private(set) var splitPct: Int = 38
    public private(set) var recents: [RecentSession] = []
    public private(set) var usage: Usage?
    public private(set) var plan: String?
    public private(set) var usageError: String?
    public private(set) var order: [String] = []
    public private(set) var projectOrder: [String] = []
    public var filter: String = ""
    public private(set) var historyMode = false
    public private(set) var focus: Focus = .terminal
    public private(set) var showSessions = true
    public private(set) var showFooter = true
    public private(set) var showHeader = true
    public private(set) var showInspector = false
    public private(set) var sbWidth = 360
    public private(set) var vimMode = false
    /// Bumped by `requestFilterFocus`; the filter field focuses on change.
    public private(set) var filterFocusTick = 0
    private(set) var inputMode: InputMode = .normal
    public private(set) var listTab: ListTab = .active
    public private(set) var recentSelected: Int?
    /// Dir to prefill in the New Session sheet (set by `N`).
    public private(set) var newSessionPrefillDir: String?
    /// Commands for the mounted terminal view (focus/scroll); set by the
    /// representable like `onTerminalOutput`.
    public var onTerminalCommand: ((TerminalCommand) -> Void)?

    /// Bytes for the currently attached session's terminal view. The terminal
    /// view mounts asynchronously after `selected` changes, so output (notably
    /// the attach backfill) can arrive before the sink exists — those bytes are
    /// buffered and flushed here the moment the view sets its sink.
    public var onTerminalOutput: (([UInt8]) -> Void)? {
        didSet {
            guard let sink = onTerminalOutput, !outputBuffer.isEmpty else { return }
            let pending = outputBuffer
            outputBuffer = []
            sink(pending)
        }
    }
    private var outputBuffer: [UInt8] = []

    private var client: IPCClient
    private let makeClient: () throws -> IPCClient
    private let store: StateStore
    private var persisted = PersistedState()   // last known full state (keeps schema-only fields)
    private var eventLoop: Task<Void, Never>?
    private let fetchAccount: () async -> Account
    private let usageInterval: TimeInterval
    private var usagePoller: Task<Void, Never>?

    public init(client: IPCClient,
                makeClient: @escaping () throws -> IPCClient,
                store: StateStore,
                fetchAccount: @escaping () async -> Account = { Account() },
                usageInterval: TimeInterval = 60) {
        self.client = client
        self.makeClient = makeClient
        self.store = store
        self.fetchAccount = fetchAccount
        self.usageInterval = usageInterval
    }

    public func start() async {
        persisted = store.load()
        themeRaw = persisted.theme ?? "dark"
        splitPct = persisted.splitPct ?? 38
        recents = persisted.recents
        order = persisted.order
        projectOrder = persisted.projectOrder
        showSessions = persisted.showSessions ?? true
        showFooter = persisted.showFooter ?? true
        showHeader = persisted.showHeader ?? true
        showInspector = persisted.showInspector ?? false
        sbWidth = persisted.sbWidth ?? 360
        vimMode = persisted.vimMode ?? true
        do {
            let (list, statuses, lost) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            connected = true
            toast = nil
            if let lost, !lost.isEmpty {
                // Sessions a dead daemon lost: surface them as relaunchable
                // recents, oldest first so the newest ends on top.
                for s in lost.sorted(by: { $0.created < $1.created }) {
                    pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent))
                }
                persist()
                try? await client.clearLost()
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
    }

    public func select(_ name: String?) async {
        guard name != selected else { return }
        if let old = selected {
            try? await client.detach(name: old)
        }
        outputBuffer = []          // drop any bytes buffered for the old session
        selected = name
        historyMode = false
        if let name {
            do { try await client.attach(name: name, sinceSeq: 0) }
            catch { toast = errorText(error) }
        }
    }

    public func create(dir: String, agent: String) async {
        do { _ = try await client.create(dir: dir, agent: agent) }
        catch { toast = errorText(error) }
    }

    public func kill(_ name: String) async {
        do { try await client.kill(name: name) }
        catch { toast = errorText(error) }
    }

    public func rename(_ name: String, to newName: String) async {
        do { try await client.rename(name: name, newName: newName) }
        catch { toast = errorText(error) }
    }

    public func sendInput(_ bytes: [UInt8]) async {
        guard let selected else { return }
        try? await client.input(name: selected, bytes: bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) async {
        guard let selected else { return }
        try? await client.resize(name: selected, cols: cols, rows: rows)
    }

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

    public func relaunchRecent(_ r: RecentSession) async {
        do { _ = try await client.create(dir: r.dir, agent: r.agent, name: r.name) }
        catch { toast = errorText(error) }
    }

    public var counts: (total: Int, running: Int, waiting: Int) {
        var r = 0, w = 0
        for s in sessions {
            switch statusByName[s.name] {
            case .running: r += 1
            case .waiting: w += 1
            default: break
            }
        }
        return (sessions.count, r, w)
    }

    /// dir groups ordered by `projectOrder` (unknown dirs appended by first
    /// appearance); within a group, sessions ordered by `order` (unknown by created).
    public func orderedSessions() -> [(dir: String, sessions: [Session])] {
        orderedDirs().map { dir in
            let inDir = sessions.filter { $0.dir == dir }.sorted { a, b in
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
    public func requestFilterFocus() { filterFocusTick += 1 }
    public func setHistoryMode(_ on: Bool) { historyMode = on }
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
        for d in projectOrder where sessions.contains(where: { $0.dir == d }) {
            if seen.insert(d).inserted { dirs.append(d) }
        }
        for s in sessions where !seen.contains(s.dir) {
            if seen.insert(s.dir).inserted { dirs.append(s.dir) }
        }
        return dirs
    }

    /// Flat visible ordering: orderedSessions() narrowed by the fuzzy filter.
    public func visibleSessionNames() -> [String] {
        orderedSessions().flatMap { group in
            group.sessions.map(\.name).filter { fuzzyMatch(filter, $0) }
        }
    }

    /// Recents hidden while a live session reuses the name (Recent tab rule).
    public func visibleRecents() -> [RecentSession] {
        let active = Set(sessions.map(\.name))
        return recents.filter { !active.contains($0.name) }
    }

    public func setListTab(_ tab: ListTab) {
        listTab = tab
        recentSelected = tab == .recent ? (visibleRecents().isEmpty ? nil : 0) : nil
    }

    public func clearNewSessionPrefill() { newSessionPrefillDir = nil }

    func apply(_ action: KeyAction) {
        switch action {
        case .selectNext: step(by: 1)
        case .selectPrev: step(by: -1)
        case .selectFirst: jump(to: 0)
        case .selectByNumber(let n):
            jump(to: n - 1)
            inputMode = .normal
        case .enterTerminal:
            if listTab == .recent {
                let items = visibleRecents()
                if let idx = recentSelected, idx < items.count {
                    let r = items[idx]
                    Task { await relaunchRecent(r) }
                }
            } else if selected != nil {
                setFocus(.terminal)
                onTerminalCommand?(.focus)
            }
        case .exitTerminal:
            setFocus(.sessions)
            onTerminalCommand?(.blur)
        case .toggleTab:
            setListTab(listTab == .active ? .recent : .active)
        case .newSession(let prefill):
            newSessionPrefillDir = prefill
                ? sessions.first(where: { $0.name == selected })?.dir : nil
            modal = .newSession
        case .killSelected:
            if let selected { modal = .kill(selected) }
        case .renameSelected:
            inputMode = .normal
            if let selected { modal = .rename(selected) }
        case .startFilter:
            requestFilterFocus()
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
            onTerminalCommand?(.scrollPage(up: up))
        case .scrollTerminalToBottom:
            onTerminalCommand?(.scrollToBottom)
        case .showHelp:
            inputMode = .help
        }
    }

    private func step(by delta: Int) {
        if listTab == .recent {
            let count = visibleRecents().count
            guard count > 0 else { recentSelected = nil; return }
            let cur = recentSelected ?? -1
            recentSelected = min(count - 1, max(0, cur + delta))
            return
        }
        let names = visibleSessionNames()
        guard !names.isEmpty else { return }
        let cur = selected.flatMap { names.firstIndex(of: $0) } ?? -1
        let next = min(names.count - 1, max(0, cur + delta))
        let name = names[next]
        Task { await select(name) }
    }

    private func jump(to index: Int) {
        if listTab == .recent {
            let count = visibleRecents().count
            guard count > 0 else { return }
            recentSelected = min(count - 1, max(0, index))
            return
        }
        let names = visibleSessionNames()
        guard !names.isEmpty else { return }
        let name = names[min(names.count - 1, max(0, index))]
        Task { await select(name) }
    }

    /// Keyboard reorder within the selected session's project group.
    private func moveSelectedSession(up: Bool) {
        guard listTab == .active, let selected else { return }
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
        persisted.recents = recents
        persisted.order = order
        persisted.projectOrder = projectOrder
        persisted.showSessions = showSessions
        persisted.showFooter = showFooter
        persisted.showHeader = showHeader
        persisted.showInspector = showInspector
        persisted.sbWidth = sbWidth
        persisted.vimMode = vimMode
        store.save(persisted)
    }

    private func tickUsage() async {
        let acc = await fetchAccount()
        usage = acc.usage
        plan = acc.plan
        usageError = acc.usageError
    }

    private func apply(_ event: DaemonEvent) {
        switch event {
        case let .sessionAdded(session):
            sessions.removeAll { $0.name == session.name }
            sessions.append(session)
            sessions.sort { $0.created < $1.created }
        case .sessionRemoved(let name):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
        case .exited(let name, _):
            if let s = sessions.first(where: { $0.name == name }) {
                pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent))
                persist()
            }
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
        case let .statusChanged(name, status):
            statusByName[name] = status
        case let .output(name, _, bytesB64):
            guard name == selected, let data = Data(base64Encoded: bytesB64) else { return }
            let bytes = [UInt8](data)
            if let sink = onTerminalOutput {
                sink(bytes)
            } else {
                outputBuffer.append(contentsOf: bytes)   // flushed when the view mounts
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if case let IPCClientError.daemonError(code, message) = error {
            return "\(code): \(message)"
        }
        return "\(error)"
    }
}
