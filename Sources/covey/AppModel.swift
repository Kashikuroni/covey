import AppKit
import Foundation
import Observation
import CoveyKit

/// ⌃1-5 zone targets (menu key equivalents — reachable from any focus).
public enum FocusZone: Equatable {
    case session, agent, issues, terminalSplit, trace
}

struct ProviderLaunch: Equatable {
    let env: [String: String]?
    let providerId: String?
}

enum ProviderKeyStatus: Equatable {
    case checking
    case set
    case missing
}

enum ProviderKeyMutationResult: Equatable {
    case success
    case failure(String)
}

/// UI state machine. The daemon is the single source of truth about sessions:
/// actions call the IPC client and the model mutates only when the daemon's
/// events confirm the change. One instance owns the single `client.events`
/// consumer (the stream delivers each element to exactly one iterator).
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable {
        case settings
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
        case logSearch
        case splitPicker(PaneAxis)
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
    /// Workspace Views (Workspace Views spec): every view keyed by id. Each
    /// session belongs to exactly one. The active view is derived from
    /// `selected` (`WorkspaceViewStore`).
    var views: [ViewID: WorkspaceView] = [:]
    var viewOfSession: [String: ViewID] = [:]
    /// Test seam for deterministic view ids.
    @ObservationIgnored var newViewID: () -> ViewID = { UUID().uuidString }
    /// Последняя фокусная agent-панель: цель замены кликом по сайдбару, пока
    /// фокус стоит на шелл-колонке.
    @ObservationIgnored var lastFocusedAgent: String?
    /// Панель-цель операций сплита: фокусная agent-панель (не колонка).
    var focusedAgentPane: String? {
        if let focusedPane, focusedPane != activeShell { return focusedPane }
        return lastFocusedAgent ?? selected
    }
    /// Дерево agent-панелей активной View, когда их ≥2; иначе nil.
    var visibleSplitTree: PaneNode? {
        guard let active = activeView, active.isSplit else { return nil }
        return active.agentTree
    }

    /// Agent-панели, которые сейчас на экране (листья активной View).
    var agentPanes: [String] {
        if let active = activeView { return active.leaves }
        return selected.map { [$0] } ?? []
    }
    /// Сколько agent-панелей сейчас в окне (лимит 8).
    var agentPaneCount: Int { agentPanes.count }
    /// Модалка провайдеров (клик по часам): мониторинг и ключ z.ai.
    public var showProvidersPanel = false {
        didSet {
            // Клавиатуру терминала отдаём шиту — как у modal.
            guard showProvidersPanel, focus == .terminal else { return }
            sendTerminalCommand(.blur)
        }
    }
    /// Шторка настроек дашборда (шестерёнка в топбаре): модели, цены,
    /// провайдеры, ключи — единое место настроек.
    public var showDashboardSettings = false {
        didSet {
            guard showDashboardSettings, focus == .terminal else { return }
            sendTerminalCommand(.blur)
        }
    }
    /// Реестр моделей дашборда (цвет/цена/архив) — общий для всех вью.
    let dashboardSettings = DashboardSettings()
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
    /// Ось, с которой открыта модалка сплита (выбор «Терминал» ось не
    /// касается — хранится на время модалки).
    @ObservationIgnored private var pendingSplitAxis: PaneAxis?
    @ObservationIgnored private var offerThemeRestartAfterModalDismiss = false
    @ObservationIgnored private var toastDismiss: Task<Void, Never>?
    /// How long a transient toast stays before auto-dismissing (test-tunable).
    @ObservationIgnored var toastDismissDelay: Duration = .seconds(4)
    public internal(set) var toast: String? {
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
    /// Stage of the in-flight session create ("updating dev…"), fed by
    /// `createProgress` events; the create sheet shows it so a long worktree
    /// create doesn't read as a hang. `createFull` clears it when it resolves.
    public internal(set) var createStage: String?
    /// What the main window shows. Not persisted: covey starts in `.sessions`.
    /// Changed only by `AppModel+Review`.
    var windowMode: WindowMode = .sessions
    /// The one live review. It survives trips back to the sessions and is
    /// replaced only when Review opens for another worktree.
    var review: ReviewModel?
    /// The main window is fully covered; the review stops polling then.
    @ObservationIgnored var mainWindowOccluded = false
    /// Bumped by every Review entry and exit, so a toplevel that git resolves
    /// for a superseded entry is dropped.
    @ObservationIgnored var reviewEntryGeneration = 0
    /// The session the last review went to ("⌥⌘R to watch"): the next trip
    /// back to the sessions selects it, once.
    @ObservationIgnored var pendingWatchSession: String?
    /// Worktree toplevel of a directory, nil outside git (test seam).
    @ObservationIgnored var resolveReviewWorktree: @Sendable (String) async -> String? = { dir in
        await AppModel.gitToplevel(dir)
    }
    /// Builds the review for an opening (test seam; nil = the production model).
    @ObservationIgnored var reviewModelFactory: ((ReviewOpening) -> ReviewModel)?
    /// The Review graph's link settings (persisted), shared with the live review.
    let reviewLinks = ReviewLinkSettings()
    public private(set) var connected = false
    public private(set) var themeRaw: String = "dark"
    public private(set) var splitPct: Int = 38
    public private(set) var usagePlacement: UsagePlacement = .right
    public private(set) var menuBarLimitsEnabled = false
    public private(set) var recents: [RecentSession] = []
    // Usage/limits state lives in UsageStore; these forwarding properties keep
    // the facade views and tests already read.
    public var usage: Usage? { usageStore.snapshot.usage }
    public var plan: String? { usageStore.snapshot.plan }
    public var usageError: String? { usageStore.snapshot.usageError }
    /// Per-provider display/polling toggle — off skips the network call (and,
    /// for Codex, tears down the whole subprocess) but keeps the last known
    /// snapshot around for the dimmed popover row.
    public var claudeUsageEnabled: Bool { usageStore.snapshot.claudeUsageEnabled }
    public var codexUsageEnabled: Bool { usageStore.snapshot.codexUsageEnabled }
    public var glmUsageEnabled: Bool { usageStore.snapshot.glmUsageEnabled }
    /// Which provider the limits detail popover highlights — j/k moves it, h/l
    /// disables/enables it. Resets to `.claude` every time the popover opens;
    /// not persisted, this is transient keyboard-navigation state.
    // Codex limits are consumed only in-module (TopBar) + @testable tests, so
    // these stay internal — their types (CodexRateLimitsSnapshot/State) are too.
    var codexUsage: CodexRateLimitsSnapshot? { usageStore.snapshot.codexUsage }
    var codexPlan: String? { usageStore.snapshot.codexPlan }
    var codexState: CodexServerState { usageStore.snapshot.codexState }
    var codexUsageError: String? {
        codexState == .unauthed ? "Codex is signed out. Sign in to Codex to resume limit updates." : nil
    }
    var glmQuota: GLMQuota? { usageStore.snapshot.glmQuota }
    var glmForecast: GLMForecast? { usageStore.snapshot.glmForecast }
    /// Провайдер-нейтральная аналитика (claude/codex без GLM-зависимости).
    var forecastAnalytics: ForecastAnalytics? { usageStore.snapshot.forecastAnalytics }
    /// Прогноз rate-limit окон Codex (этап 2).
    var codexForecast: CodexForecast? { usageStore.snapshot.codexForecast }
    var glmUsageError: String? { usageStore.snapshot.glmUsageError }
    /// GLM's z.ai API key presence. Unlike Claude/Codex, GLM has no local
    /// login to read — the key is entered in the limits window.
    private(set) var glmAPIKeyStatus: ProviderKeyStatus = .checking
    /// Key present AND the last fetch came back without errors — the limits
    /// window's "api key — valid" state.
    var glmAPIKeyValid: Bool {
        glmAPIKeyStatus == .set && glmQuota != nil && glmUsageError == nil
    }

    /// Loads GLM key presence without blocking the main actor.
    func refreshGLMAPIKeyStatus() async {
        glmAPIKeyStatus = .checking
        let reader = readProviderKey
        let present = await Task.detached(priority: .userInitiated) {
            reader(glmKeychainAccount) != nil
        }.value
        guard !Task.isCancelled else { return }
        glmAPIKeyStatus = present ? .set : .missing
    }

    /// Stores the z.ai API key, verifies the exact value landed in the
    /// Keychain, and nudges the daemon so quota data arrives without waiting
    /// for the poll tick. Saving while polling is off re-enables it —
    /// otherwise the just-saved key could never turn the row valid.
    /// Returns false when the write could not be verified.
    func setGLMAPIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let write = writeProviderKey
        let reader = readProviderKey
        let verified = await Task.detached(priority: .userInitiated) {
            guard write(glmKeychainAccount, trimmed) else { return false }
            return reader(glmKeychainAccount) == trimmed
        }.value
        guard verified else { return false }
        glmAPIKeyStatus = .set
        if glmUsageEnabled {
            await refreshUsage(.glm)
        } else {
            // The daemon fetches on its own right after enabling (and the
            // enable is serialized on the daemon side, unlike a bare refresh).
            setGlmUsageEnabled(true)
        }
        return true
    }
    public private(set) var order: [String] = []
    public private(set) var projectOrder: [String] = []
    public var filter: String = ""
    public private(set) var historyMode = false
    public private(set) var focus: Focus = .sessions
    public private(set) var showSessions = true
    public private(set) var showFooter = true
    public private(set) var showHeader = true
    /// Inspector open/closed lives on the active view; a bare project (no
    /// session) always shows it (issues is its only content).
    public var showInspector: Bool {
        if let active = activeView { return active.inspector.isShown }
        return selectedProjectRoot != nil
    }
    /// The right drawer shows either GitHub Issues or the selected agent's trace.
    public enum InspectorMode: String, Equatable { case issues, trace }
    public var inspectorMode: InspectorMode { activeView?.inspector.mode ?? .issues }
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
    /// Bumped when Create GitHub Issue activates the composer title field.
    public private(set) var issueFocusTick = 0
    public private(set) var sbWidth = 360
    public private(set) var vimMode = false
    /// The footer filter is showing (activated by `/` or ⌘F).
    public private(set) var filterActive = false
    private(set) var inputMode: InputMode = .normal
    public private(set) var commandPalettePresented = false
    /// Dir to prefill in the New Session sheet (set by `N`).
    public private(set) var newSessionPrefillDir: String?
    /// Issue number the pending New Session is being created for (issue's `s`);
    /// the sheet records the binding on the created session's name.
    public private(set) var newSessionPrefillIssue: Int?
    /// Branch to prefill (create-session-in-branch from an issue).
    public private(set) var newSessionPrefillBranch: String?
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
    private var terminalPaneOwnership = TerminalPaneOwnership()
    /// Как каждая смонтированная панель забирает сессию себе. Живёт до сноса
    /// панели, чтобы владение можно было ПЕРЕДАТЬ, а не только отобрать.
    @ObservationIgnored
    private var paneClaims: [TerminalViewLease: () -> Void] = [:]
    /// Names this client is attached to (все панели дерева + колонка):
    /// инвариант спеки — под ним стоит гард доставки `.output`.
    internal private(set) var attachedNames: Set<String> = []

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
        if let target { deliverTerminalCommand(cmd, to: target) }
    }

    /// The one way a command reaches a terminal view. Review hides the
    /// terminals; none may take the keyboard behind it (sheet dismissal, the
    /// palette, the limits overlay and `focusPane` all ask).
    private func deliverTerminalCommand(_ cmd: TerminalCommand, to name: String) {
        if cmd == .focus, windowMode == .review { return }
        terminalCommands[name]?(cmd)
    }

    var client: IPCClient
    private let makeClient: () throws -> IPCClient
    let store: StateStore
    var persisted = PersistedState()   // last known full state (keeps schema-only fields)
    private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var sessionCycleTarget: String?
    @ObservationIgnored private var sessionCycleTask: Task<Void, Never>?
    private var usageStore: UsageStore!
    private let readProviderKey: @Sendable (String) -> String?
    private let writeProviderKey: @Sendable (String, String) -> Bool
    private let deleteProviderKey: @Sendable (String) -> Bool
    private(set) var providerKeyStatuses: [String: ProviderKeyStatus] = [:]

    public init(client: IPCClient,
                makeClient: @escaping () throws -> IPCClient,
                store: StateStore,
                readProviderKey: (@Sendable (String) -> String?)? = nil,
                writeProviderKey: (@Sendable (String, String) -> Bool)? = nil,
                deleteProviderKey: (@Sendable (String) -> Bool)? = nil) {
        self.readProviderKey = readProviderKey ?? {
            ProviderKeychain.read(account: $0)
        }
        self.writeProviderKey = writeProviderKey ?? {
            ProviderKeychain.write(account: $0, value: $1)
        }
        self.deleteProviderKey = deleteProviderKey ?? {
            ProviderKeychain.delete(account: $0)
        }
        // Created before any self-capturing closures below.
        issueBrowser = IssueBrowserModel(
            fetchIssues: { dir, state in await IssueService.list(dir: dir, state: state) },
            fetchLabels: { dir in await IssueService.labelList(dir: dir) },
            runMutation: { args, dir in await IssueService.mutate(args: args, dir: dir) })
        self.client = client
        self.makeClient = makeClient
        self.store = store
        // Created before any self-capturing closures read usage state.
        usageStore = UsageStore(
            onPersist: { [weak self] in self?.persist() },
            readMarkers: { [weak self] in self?.persisted.usageNotified ?? [:] },
            writeMarkers: { [weak self] in self?.persisted.usageNotified = $0 },
            glmForecastConfig: CoveyConfig.load().glmForecast ?? GLMForecastConfigSection())
        issueBrowser.toast = { [weak self] msg in self?.showToast(msg) }
        reviewLinks.changed = { [weak self] in self?.persist() }
        issueBrowser.fetchBranches = { [weak self] dir in
            await self?.gitInfo(dir).branches ?? []
        }
    }

    public func start() async {
        persisted = store.load()
        themeRaw = persisted.theme ?? "dark"
        splitPct = persisted.splitPct ?? 38
        usagePlacement = persisted.usagePlacement.flatMap(UsagePlacement.init(rawValue:)) ?? .right
        menuBarLimitsEnabled = persisted.menuBarLimitsEnabled ?? false
        recents = persisted.recents
        order = persisted.order
        projectOrder = persisted.projectOrder
        showSessions = persisted.showSessions ?? true
        showFooter = persisted.showFooter ?? true
        showHeader = persisted.showHeader ?? true
        sbWidth = persisted.sbWidth ?? 360
        vimMode = persisted.vimMode ?? true
        reviewLinks.showLinks = persisted.showLinks ?? false
        reviewLinks.linksOnFocus = persisted.linksOnFocus ?? true
        projectNames = persisted.projectNames
        projects = persisted.projects ?? []
        do {
            let (list, statuses, lost, models) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            modelByName = models
            connected = true
            toast = nil
            // Legacy: the oldest `splitAxes` payload keeps one companion shell;
            // the workspace-view migration then folds it into a view.
            var legacyShell: String?
            if let axes = persisted.splitAxes, !axes.isEmpty {
                legacyShell = await restoreLegacySplitAxes(axes)
            }
            // Workspace Views: load persisted views, or migrate the legacy
            // splitTree + companionShell + inspector on first run.
            loadOrMigrateViews(legacyShell: legacyShell)
            if let lost, !lost.isEmpty {
                // Sessions a dead daemon lost: surface them as relaunchable
                // recents, oldest first so the newest ends on top.
                for s in lost.sorted(by: { $0.created < $1.created }) {
                    pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent,
                                                       resumeCmd: s.resumeCmd,
                                                       stoppedAt: Int64(Date().timeIntervalSince1970),
                                                       providerId: s.providerId))
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
        usageStore.beginSubscription()
        do {
            usageStore.apply(try await client.usageSubscribe())
        } catch {
            usageStore.failed(error)
        }
        // Inherits MainActor: apply() and the trailing mutations run on the actor.
        eventLoop = Task { [client] in
            for await event in client.events {
                self.apply(event)
            }
            guard !Task.isCancelled, self.client === client else { return }
            self.connected = false
            self.usageStore.disconnected()
            self.toast = "daemon connection lost"
        }
        // Event loop is up: relink / respawn each view's shell without blocking
        // the first paint.
        Task { await relinkOrRespawnShells() }
    }

    /// Selection only — does not move keyboard focus into the pane (j/k walks
    /// the list, Enter / ⌃2 focuses the agent). Setting `selected` re-picks the
    /// active view, so selecting any leaf of a hidden split brings its whole
    /// grid back.
    public func select(_ name: String?) async {
        guard let name else { await clearSelection(); return }
        guard name != selected else { return }
        selected = name
        selectedProjectRoot = nil
        focusedPane = name
        lastFocusedAgent = name
        historyMode = false
        await syncPaneAttachments()
        if inspectorMode == .trace { await subscribeTrace() }
    }

    /// Выход из воркспейса: единственное место с полным detach (спека).
    private func clearSelection() async {
        for n in attachedNames { try? await client.detach(name: n) }
        attachedNames = []
        outputBuffers = [:]
        selected = nil
        focusedPane = nil
        lastFocusedAgent = nil
        historyMode = false
    }

    /// Приводит attach к тому, что показано: панели ушедшей с экрана сетки
    /// отвязываются, вернувшиеся — привязываются. Шелл-колонка живёт своей
    /// жизнью и в расчёт входит как есть.
    private func syncPaneAttachments() async {
        var wanted = Set(agentPanes)
        if let shell = activeShell { wanted.insert(shell) }
        for name in wanted where !attachedNames.contains(name) {
            await attachPane(name)
        }
        for name in attachedNames.subtracting(wanted) {
            await detachPane(name)
        }
    }

    /// Точечная отвязка панели: буфер чистится только у неё (спека «Attach-цикл»).
    private func detachPane(_ name: String) async {
        guard attachedNames.contains(name) else { return }
        attachedNames.remove(name)
        outputBuffers[name] = nil
        try? await client.detach(name: name)
    }

    public func setInspectorMode(_ mode: InspectorMode) {
        mutateActiveView { $0.inspector = .shown(mode: mode) }
        if mode == .trace { Task { await subscribeTrace() } }
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

    func attachPane(_ name: String) async {
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
        if name == activeShell {
            // Инвариант: фокус на колонке не меняет selected.
            setFocus(.terminal)
        } else {
            // Инвариант спеки: selected = сессия фокусной agent-панели.
            selected = name
            lastFocusedAgent = name
            setFocus(.terminal)
        }
        deliverTerminalCommand(.focus, to: name)
    }

    public func create(dir: String, agent: String) async {
        do { _ = try await client.create(dir: dir, agent: agent) }
        catch { toast = errorText(error) }
    }

    /// Драг деляты узла активной View: путь из `PanelLayout.SplitDivider.path`
    /// (пустой путь — корневой узел дерева).
    func setSplitRatio(path: [Int], ratio: Double) {
        mutateActiveView {
            $0.agentTree = PaneNode.setRatio($0.agentTree, path: path,
                                             ratio: min(0.85, max(0.15, ratio))) ?? $0.agentTree
        }
    }

    func setCompanionRatio(_ ratio: Double) {
        mutateActiveView { $0.agentAreaRatio = min(0.85, max(0.15, ratio)) }
    }

    /// Oldest legacy format (`splitAxes`): keep the first live companion pair by
    /// sidebar order as a single shell, close the rest. Returns the surviving
    /// shell name for `loadOrMigrateViews` to fold into a view; clears `splitAxes`.
    func restoreLegacySplitAxes(_ axes: [String: String]) async -> String? {
        guard !axes.isEmpty else { return nil }
        let pairs = sessions.compactMap { s -> (parent: String, companion: String)? in
            guard let parent = s.companionOf else { return nil }
            return (parent: parent, companion: s.name)
        }
        let ordered = orderedSessions().flatMap(\.sessions).map(\.name)
        persisted.splitAxes = nil
        guard let choice = splitMigrationChoice(parentCompanions: pairs,
                                                orderedParentNames: ordered) else {
            return nil
        }
        for shell in choice.close { await kill(shell) }
        return choice.keep.companion
    }

    @discardableResult
    public func kill(_ name: String, removeWorktree: Bool = false,
                     deleteBranch: Bool = false) async -> String? {
        do {
            try await client.kill(name: name,
                                  removeWorktree: removeWorktree ? true : nil,
                                  deleteBranch: deleteBranch ? true : nil)
            return nil
        } catch {
            let message = errorText(error)
            toast = message
            return message
        }
    }

    /// Restart via the daemon; the error text doubles as the sheet's inline
    /// banner. `dir` overrides the respawn directory (return-to-root).
    @discardableResult
    public func restart(_ name: String, dir: String? = nil) async -> String? {
        do { try await client.restart(name: name, dir: dir); return nil }
        catch { let msg = errorText(error); toast = msg; return msg }
    }

    /// The bulk restart command: every session whose agent's first word is
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
            toast = "\(plan.busy.count) agent(s) keep old theme — restart when idle (Command-P › Restart All Claude Sessions)"
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
        let (resolved, providerError) = Self.resolveProviderLaunch(
            agent: agent, selectedProviderId: nil
        )
        if let providerError { return providerError }
        guard let resolved else { return "Unable to resolve Claude Code provider." }
        if resolved.providerId != nil {
            let settingsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json").path
            let conflicts = Self.anthropicManagedKeys(inSettingsAt: settingsPath)
            if !conflicts.isEmpty {
                toast = "~/.claude/settings.json sets \(conflicts.joined(separator: ", ")); it overrides Covey. Remove those keys or they'll win."
            }
        }
        // Stage events only flow while the request is in flight; whatever the
        // loop last saw must not outlive this call (success or error).
        defer { createStage = nil }
        do {
            let s = try await client.create(dir: dir, agent: agent, name: name,
                                            terminal: terminal ? true : nil,
                                            worktree: worktree, model: model,
                                            effort: effort, env: resolved.env,
                                            providerId: resolved.providerId)
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
        if var map = persisted.issueBySession, let issue = map.removeValue(forKey: name) {
            map[newName] = issue
            persisted.issueBySession = map
        }
        // Pane identities are session names: migrate the owning view.
        renameSessionInView(name, to: newName)
        if focusedPane == name { focusedPane = newName }
        if lastFocusedAgent == name { lastFocusedAgent = newName }
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
        terminalPaneOwnership.mount(session: name)
    }

    /// Панель объявляет, как забрать сессию себе (сток вывода + текущая сетка).
    /// Заявка исполняется сразу, если панель — владелец, и хранится до сноса:
    /// когда владельца сносят, сессия переходит по ней оставшейся панели.
    func registerPane(_ lease: TerminalViewLease, claim: @escaping () -> Void) {
        paneClaims[lease] = claim
        if terminalPaneOwnership.isCurrent(lease) { claim() }
    }

    func unmountTerminalView(_ lease: TerminalViewLease) {
        paneClaims[lease] = nil
        switch terminalPaneOwnership.unmount(lease) {
        case .none:
            break
        case .vacant:
            // Панелей на сессию не осталось: вывод копится в буфере и
            // достанется следующей — вместо того чтобы уйти в снесённый view.
            setTerminalSink(for: lease.session, nil)
        case .passed(let successor):
            // Наследник мог простоять без стока сколько угодно: ему нужен и
            // сток, и повтор вывода от демона.
            paneClaims[successor]?()
            paneViewMounted(successor.session)
        }
    }

    func isTerminalViewLeaseCurrent(_ lease: TerminalViewLease) -> Bool {
        terminalPaneOwnership.isCurrent(lease)
    }

    /// Resize requests sent to the daemon — each one is a SIGWINCH for the
    /// agent if the size moved. Tests pin that a mode switch sends none.
    @ObservationIgnored private(set) var resizesSent = 0

    func resize(
        cols: UInt16,
        rows: UInt16,
        lease: TerminalViewLease
    ) async {
        guard isTerminalViewLeaseCurrent(lease) else { return }
        resizesSent += 1
        try? await client.resize(
            name: lease.session,
            cols: cols,
            rows: rows
        )
    }

    /// Sheets fire-and-forget outcomes (issue created after Esc-hide, …).
    public func showToast(_ message: String) {
        EventLog.note("toast", message)
        toast = message
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
        let clamped = min(PanelLayout.maxSessionSplitPercent,
                          max(PanelLayout.minSessionSplitPercent, pct))
        guard clamped != splitPct else { return }
        splitPct = clamped
        persist()
    }

    @discardableResult
    public func relaunchRecent(_ r: RecentSession, activate: Bool = true) async -> Bool {
        // Keep the provider the session originally used; legacy recents are
        // Anthropic. Non-Claude agents always resolve to a neutral launch.
        let selectedId = r.providerId ?? ProviderProfile.anthropic.id
        let (resolved, providerError) = Self.resolveProviderLaunch(
            agent: r.agent, selectedProviderId: selectedId
        )
        if let providerError { toast = providerError; return false }
        guard let resolved else { return false }
        do {
            let s = try await client.create(dir: r.dir, agent: r.agent, name: r.name,
                                            resume: r.resumeCmd, env: resolved.env,
                                            providerId: resolved.providerId)
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

    /// Sessions that get cards/numbers/counts — companions and hidden
    /// workspace-view shells are invisible.
    public var visibleSessions: [Session] {
        sessions.filter { $0.companionOf == nil && $0.hidden != true }
    }

    public func companion(of name: String) -> Session? {
        sessions.first { $0.companionOf == name }
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

    /// Группы сайдбара: Split View сверху отдельной сущностью, ниже проекты
    /// без уехавших в сплит сессий (`SidebarLayout`).
    func sidebarGroups() -> [SidebarGroup] {
        SidebarLayout.groups(projects: orderedSessions(), views: Array(views.values))
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
    public func setShowInspector(_ on: Bool) {
        mutateActiveView { v in
            v.inspector = on ? .shown(mode: v.inspector.mode ?? .issues) : .hidden
        }
    }
    public func setVimMode(_ on: Bool) { vimMode = on; persist() }

    var settingsValues: SettingsValues {
        SettingsValues(theme: Theme(raw: themeRaw),
                       vimMode: vimMode, showSessions: showSessions,
                       showHeader: showHeader, showFooter: showFooter,
                       usagePlacement: usagePlacement,
                       claudeUsageEnabled: claudeUsageEnabled,
                       codexUsageEnabled: codexUsageEnabled,
                       glmUsageEnabled: glmUsageEnabled,
                       linksOnFocus: reviewLinks.linksOnFocus)
    }

    func openSettings() {
        guard modal == nil else { return }
        modal = .settings
    }

    /// Stores (or clears) a provider key and verifies the final Keychain state
    /// without blocking the main actor.
    func setProviderKey(
        _ profile: ProviderProfile,
        _ key: String
    ) async -> ProviderKeyMutationResult {
        let failure = ProviderKeyMutationResult.failure(
            "Couldn’t save API key. Check Keychain access and try again."
        )
        guard let account = profile.keychainAccount else { return failure }
        let reader = readProviderKey
        if key.isEmpty {
            let delete = deleteProviderKey
            let verified = await Task.detached(priority: .userInitiated) {
                guard delete(account) else { return false }
                return reader(account) == nil
            }.value
            guard verified else { return failure }
            providerKeyStatuses[account] = .missing
            return .success
        } else {
            let write = writeProviderKey
            let verified = await Task.detached(priority: .userInitiated) {
                guard write(account, key) else { return false }
                return reader(account) == key
            }.value
            guard verified else { return failure }
            providerKeyStatuses[account] = .set
            return .success
        }
    }

    /// Cached key status safe to read while SwiftUI is building a view.
    func providerKeyStatus(_ profile: ProviderProfile) -> ProviderKeyStatus {
        guard let account = profile.keychainAccount else { return .set }
        return providerKeyStatuses[account] ?? .checking
    }

    /// Loads key presence without blocking the main actor or SwiftUI rendering.
    func refreshProviderKeyStatuses(_ profiles: [ProviderProfile]) async {
        let accounts = Set(profiles.compactMap(\.keychainAccount))
        for account in accounts {
            providerKeyStatuses[account] = .checking
        }
        let reader = readProviderKey
        let present = await Task.detached(priority: .userInitiated) {
            Set(accounts.filter { reader($0) != nil })
        }.value
        guard !Task.isCancelled else { return }
        for account in accounts {
            providerKeyStatuses[account] = present.contains(account) ? .set : .missing
        }
    }

    /// Resolves the env block to inject for provider `id` (reads the Keychain).
    /// Returns nil env for anthropic (no injection) or an unknown id; returns a
    /// user-facing `error` when a needed API key is absent so callers can surface
    /// it instead of spawning a session that will immediately 401.
    nonisolated static func resolveProviderEnv(_ id: String) -> (env: [String: String]?, error: String?) {
        guard let profile = ProviderRegistry.profile(id: id) else { return (nil, nil) }
        do {
            let env = try ProviderResolver.resolve(profile: profile) { account in
                ProviderKeychain.read(account: account)
            }
            return (env.isEmpty ? nil : env, nil)
        } catch {
            return (nil, "Set your \(profile.label) API key in Settings first.")
        }
    }

    /// Resolves the provider block for one new process. Provider overrides are
    /// valid only for the exact Claude preset; every other agent stays neutral.
    nonisolated static func resolveProviderLaunch(
        agent: String,
        selectedProviderId: String?
    ) -> (launch: ProviderLaunch?, error: String?) {
        guard agent == "claude" else {
            return (ProviderLaunch(env: nil, providerId: nil), nil)
        }
        let id = selectedProviderId ?? ProviderProfile.anthropic.id
        guard ProviderRegistry.profile(id: id) != nil else {
            return (nil, "Unknown Claude Code provider: \(id)")
        }
        let resolved = resolveProviderEnv(id)
        if let error = resolved.error { return (nil, error) }
        return (ProviderLaunch(
            env: resolved.env,
            providerId: id == ProviderProfile.anthropic.id ? nil : id
        ), nil)
    }

    /// The `ANTHROPIC_*` env keys Covey may set for a provider. Claude Code's
    /// settings.json `env` block overrides the process environment, so any of
    /// these present in `~/.claude/settings.json` would silently override
    /// Covey's provider choice.
    nonisolated static let managedKeys = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
    ]

    /// Which managed `ANTHROPIC_*` keys a Claude Code settings file's `env`
    /// block pins (and would therefore override Covey). Empty when there is no
    /// conflict, no `env` block, or no file.
    nonisolated static func anthropicManagedKeys(inSettingsAt path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return [] }
        return managedKeys.filter { env[$0] != nil }
    }

    func openCommandPalette() {
        guard modal == nil else { return }
        inputMode = .normal
        commandPalettePresented = true
    }

    func closeCommandPalette() {
        commandPalettePresented = false
    }

    func toggleCommandPalette() {
        commandPalettePresented ? closeCommandPalette() : openCommandPalette()
    }

    func restoreCommandPaletteTerminalFocus() {
        guard modal == nil, focus == .terminal else { return }
        sendTerminalCommand(.focus)
    }

    func commandAvailability(_ command: AppCommand) -> CommandAvailability {
        CommandRules.availability(for: command, context: commandContext)
    }

    private var commandContext: CommandContext {
        let session = selectedSession()
        let group = session.flatMap { selected in
            orderedSessions().first { group in
                group.sessions.contains { $0.name == selected.name }
            }
        }
        let index = group.flatMap { group in
            session.flatMap { selected in
                group.sessions.firstIndex { $0.name == selected.name }
            }
        }
        let canMoveDown: Bool
        if let index, let count = group?.sessions.count {
            canMoveDown = index < count - 1
        } else {
            canMoveDown = false
        }

        return CommandContext(
            hasSelectedSession: session != nil,
            hasProject: inspectorRoot != nil,
            selectedHasGit: session?.git != nil,
            selectedIsWorktree: session?.worktreeRepo != nil,
            selectedBranch: session?.git?.branch,
            selectedBranchProtected: session?.git.map {
                protectedBranches.contains($0.branch)
            } ?? false,
            selectedCanReturnToRoot: session.map { isReturnable($0) } ?? false,
            hasTerminalSplit: activeView?.terminal != nil,
            inspectorShown: showInspector,
            hasClaudeSessions: visibleSessions.contains {
                $0.agent.split(separator: " ").first == "claude"
            },
            visibleSessionCount: visibleSessionNames().count,
            canMoveSessionUp: index.map { $0 > 0 } ?? false,
            canMoveSessionDown: canMoveDown,
            terminalFocused: focus == .terminal && inputMode == .normal,
            agentPaneCount: agentPaneCount,
            canCloseFocusedPane: focusedPane == activeShell
                || (visibleSplitTree?.contains(session: focusedPane ?? "") ?? false),
            reviewOpen: windowMode == .review,
            hasActiveReview: review != nil)
    }

    func perform(_ command: AppCommand) {
        guard commandAvailability(command).isEnabled else { return }
        closeCommandPalette()
        inputMode = .normal

        switch command {
        case .newSession:
            newSessionPrefillDir = nil
            modal = .newSession
        case .newSessionInCurrentProject:
            newSessionPrefillDir = inspectorRoot
            modal = .newSession
        case .recentSessions:
            modal = .recent
        case .filterSessions:
            filterActive = true
        case .selectPreviousSession:
            cycleSession(by: -1)
        case .selectNextSession:
            cycleSession(by: 1)
        case .selectSession1, .selectSession2, .selectSession3,
             .selectSession4, .selectSession5, .selectSession6,
             .selectSession7, .selectSession8, .selectSession9:
            selectSession(at: command.sessionSelectionIndex)
        case .killSession:
            modal = selected.map(Modal.kill)
        case .renameSession:
            modal = selected.map(Modal.rename)
        case .restartSession:
            modal = selected.map(Modal.restart)
        case .restartAllClaudeSessions:
            modal = .restartAll
        case .moveSessionUp:
            moveSelectedSession(up: true)
        case .moveSessionDown:
            moveSelectedSession(up: false)

        case .createGitHubIssue:
            if !showInspector { setShowInspector(true) }
            issueScreen = .composer
            setFocus(.inspector)
            activateIssues()
        case .openIssueList:
            if !showInspector { setShowInspector(true) }
            issueScreen = .browser
            issueBrowser.screen = .list
            setFocus(.inspector)
            activateIssues()
        case .toggleReview:
            Task { await toggleReview() }
        case .promoteWorktree:
            modal = selected.map(Modal.promote)
        case .deleteSessionBranch:
            guard let session = selectedSession(), session.worktreeRepo == nil,
                  let branch = session.git?.branch,
                  !protectedBranches.contains(branch) else { return }
            modal = .deleteBranch(session.name)
        case .cleanupMergedBranches:
            if let session = selectedSession() { modal = .cleanup(session.dir) }
        case .returnToRepositoryRoot:
            guard let session = selectedSession(), isReturnable(session),
                  let root = session.worktreeRepo else { return }
            if session.agent.split(separator: " ").first == "claude" {
                Task { await restart(session.name, dir: root) }
            } else {
                let command = "cd \(shellSingleQuote(root))\n"
                Task {
                    try? await client.input(name: session.name, bytes: Array(command.utf8))
                }
            }

        case .splitTerminalVertically:
            openSplitPicker(axis: .vertical)
        case .splitTerminalHorizontally:
            openSplitPicker(axis: .horizontal)
        case .closeTerminalSplit:
            closeFocusedPane()
        case .toggleViewTerminal:
            Task { await toggleActiveTerminal() }

        case .toggleSessionsPanel:
            setShowSessions(!showSessions)
        case .toggleInspector:
            if showInspector, focus == .inspector { setFocus(.sessions) }
            setShowInspector(!showInspector)
        case .toggleAgentTrace:
            if showInspector, inspectorMode == .trace {
                if focus == .inspector { setFocus(.sessions) }
                setInspectorMode(.issues)
                setShowInspector(false)
            } else {
                if !showInspector { setShowInspector(true) }
                sendTerminalCommand(.blur)
                setFocus(.inspector)
                setInspectorMode(.trace)
            }
        case .toggleStatusBar:
            setShowFooter(!showFooter)
        case .toggleTopBar:
            setShowHeader(!showHeader)
        case .toggleTheme:
            setTheme(themeRaw == "dark" ? "light" : "dark")
            offerThemeRestart()
        case .showProviders:
            showProvidersPanel = true
        case .toggleForecast:
            // ⌘L: the full-window limits + forecast screen. A toggle, like
            // the top bar segment — nothing is torn down on the way back.
            if windowMode == .forecast {
                windowMode = .sessions
                syncReviewVisibility()
            } else {
                enterForecast()
            }
        case .focusSessionList:
            focusZone(.session)
        case .focusAgent:
            focusZone(.agent)
        case .focusIssues:
            focusZone(.issues)
        case .focusTerminalSplit:
            focusZone(.terminalSplit)
        case .focusTrace:
            focusZone(.trace)
        case .showKeyboardHelp:
            inputMode = .help

        case .addProject:
            modal = .addProject
        case .removeProject:
            if let root = inspectorRoot { removeProject(root) }
        case .renameProject:
            if let root = inspectorRoot { modal = .renameProject(root) }
        case .settings:
            openSettings()
        case .searchLogs:
            modal = .logSearch
        }
    }

    func applySettings(_ values: SettingsValues) {
        let old = settingsValues
        guard values != old else {
            modal = nil
            return
        }
        let themeChanged = values.theme != old.theme
        themeRaw = values.theme.rawValue
        vimMode = values.vimMode
        showSessions = values.showSessions
        showHeader = values.showHeader
        showFooter = values.showFooter
        usagePlacement = values.usagePlacement
        reviewLinks.linksOnFocus = values.linksOnFocus
        if values.claudeUsageEnabled != old.claudeUsageEnabled { setClaudeUsageEnabled(values.claudeUsageEnabled) }
        if values.codexUsageEnabled != old.codexUsageEnabled { setCodexUsageEnabled(values.codexUsageEnabled) }
        if values.glmUsageEnabled != old.glmUsageEnabled { setGlmUsageEnabled(values.glmUsageEnabled) }
        persist()
        offerThemeRestartAfterModalDismiss = themeChanged
        modal = nil
    }

    func modalDidDismiss() {
        guard modal == nil, offerThemeRestartAfterModalDismiss else { return }
        offerThemeRestartAfterModalDismiss = false
        offerThemeRestart()
    }

    public var usageConnectionError: String? { usageStore.connectionError }
    public var usageSettingsAvailable: Bool { usageStore.isAvailable }
    public var usageSettingsPending: Bool { pendingUsageCommands > 0 }
    private var pendingUsageCommands = 0
    private var usageCommandTask: Task<Void, Never>?

    public func setClaudeUsageEnabled(_ on: Bool) { setUsageEnabled(.claude, on) }
    public func setCodexUsageEnabled(_ on: Bool) { setUsageEnabled(.codex, on) }
    public func setGlmUsageEnabled(_ on: Bool) { setUsageEnabled(.glm, on) }

    public func setMenuBarLimitsEnabled(_ on: Bool) {
        menuBarLimitsEnabled = on
        persist()
    }

    private func setUsageEnabled(_ provider: UsageProvider, _ enabled: Bool) {
        let previous = usageCommandTask
        let connection = client
        pendingUsageCommands += 1
        usageCommandTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.pendingUsageCommands -= 1 }
            guard self.client === connection else { return }
            do {
                let snapshot = try await connection.usageSetEnabled(provider: provider, enabled: enabled)
                guard self.client === connection else { return }
                self.usageStore.apply(snapshot)
            } catch {
                guard self.client === connection else { return }
                self.usageStore.failed(error)
                self.showToast("Could not change limits settings: \(error)")
            }
        }
    }

    private func refreshUsage(_ provider: UsageProvider) async {
        let connection = client
        do {
            let snapshot = try await connection.usageRefresh(provider: provider)
            guard client === connection else { return }
            usageStore.apply(snapshot)
        } catch {
            guard client === connection else { return }
            usageStore.failed(error)
        }
    }

    public func setSbWidth(_ px: Int) {
        let clamped = min(PanelLayout.maxInspectorWidth,
                          max(PanelLayout.minInspectorWidth, px))
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

    /// Flat visible ordering: sidebarGroups() narrowed by the fuzzy filter.
    /// Источник — тот же, что рисует список, иначе j/k и ⌘1…9 ходят не по
    /// тем карточкам, что видит пользователь (Split View стоит сверху).
    public func visibleSessionNames() -> [String] {
        sidebarGroups().flatMap { group in
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
        sidebarGroups().flatMap { group -> [ListRow] in
            let names = group.sessions.map(\.name).filter { fuzzyMatch(filter, $0) }
            if !names.isEmpty { return names.map(ListRow.session) }
            // Ghost — только у настоящего проекта; Split View пустым не бывает.
            if let dir = group.dir, group.sessions.isEmpty, filter.isEmpty {
                return [.ghost(dir)]
            }
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

    public func setProjectName(dir: String, name: String) {
        if name.isEmpty { projectNames[dir] = nil } else { projectNames[dir] = name }
        persist()
    }

    public func displayName(forDir dir: String) -> String {
        projectNames[dir] ?? projectDefaultName(dir)
    }

    func apply(_ action: KeyAction) {
        switch action {
        case .command(let command):
            perform(command)
        case .selectNext: step(by: 1)
        case .selectPrev: step(by: -1)
        case .selectFirst: jump(to: 0)
        case .selectByNumber(let n):
            jump(to: n - 1)
            inputMode = .normal
        case .exitTerminal:
            setFocus(.sessions)
            sendTerminalCommand(.blur)
        case .closeOverlay:
            inputMode = .normal
        case .enterSelectMode:
            inputMode = .selectSession
        case .resizeSplit(let delta):
            setSplitPct(splitPct + delta)
        case .scrollTerminalPage(let up):
            sendTerminalCommand(.scrollPage(up: up))
        case .scrollTerminalToBottom:
            sendTerminalCommand(.scrollToBottom)
        case .sendShiftTab:
            guard let selected else { return }
            Task { try? await client.input(name: selected, bytes: [0x1b, 0x5b, 0x5a]) }
        case .sendShiftEnter:
            // ESC CR — the newline-in-composer sequence Claude Code's own
            // /terminal-setup binds in iTerm2, and the bytes ⌥Enter already
            // sends here. Goes to the focused pane, not just the selected one,
            // so a split's shell companion gets its own ⇧Enter.
            guard let target = focusedPane ?? selected else { return }
            Task { try? await client.input(name: target, bytes: [0x1b, 0x0d]) }
        case .splitFocusToggle:
            guard let shell = activeShell else { return }
            focusPane(focusedPane == shell ? (focusedAgentPane ?? shell) : shell)
        case .cycleFocus(let forward):
            cycleFocus(forward: forward)
        }
    }

    /// ⌃h/⌃l: walk the session list, agent pane, companion shell pane (when
    /// split), and inspector (when shown), wrapping at the ends.
    /// Direct zone jump for the View-menu ⌃1-5 items. Guards toast instead
    /// of mutating anything (spec: no auto-show inspector, no auto-split).
    public func focusZone(_ zone: FocusZone) {
        switch zone {
        case .session:
            sendTerminalCommand(.blur)
            setFocus(.sessions)
        case .agent:
            guard let target = focusedAgentPane else { toast = "no session"; return }
            focusPane(target)
        case .issues:
            guard showInspector else {
                toast = "inspector hidden — Command-P › Toggle Inspector"
                return
            }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            activateIssues()
        case .terminalSplit:
            guard let shell = activeShell else {
                toast = "no terminal — Command-P › Open Terminal"
                return
            }
            focusPane(shell)
        case .trace:
            guard showInspector else {
                toast = "inspector hidden — Command-P › Toggle Inspector"
                return
            }
            sendTerminalCommand(.blur)
            setFocus(.inspector)
            setInspectorMode(.trace)
        }
    }

    private func cycleFocus(forward: Bool) {
        var zones: [(id: String, activate: () -> Void)] = [
            ("sessions", { self.sendTerminalCommand(.blur); self.setFocus(.sessions) })
        ]
        if let tree = visibleSplitTree {
            for leaf in tree.leaves {
                zones.append(("pane:\(leaf)", { self.focusPane(leaf) }))
            }
        } else if let selected {
            zones.append(("pane:\(selected)", { self.focusPane(selected) }))
        }
        if let shell = activeShell {
            zones.append(("pane:\(shell)", { self.focusPane(shell) }))
        }
        if showInspector {
            zones.append(("inspector", {
                self.sendTerminalCommand(.blur)
                self.setFocus(.inspector)
                if self.inspectorMode == .issues { self.activateIssues() }
            }))
        }
        let currentID: String
        switch focus {
        case .sessions: currentID = "sessions"
        case .inspector: currentID = "inspector"
        case .terminal: currentID = "pane:\(focusedPane ?? selected ?? "")"
        }
        let idx = zones.firstIndex { $0.id == currentID } ?? 0
        let next = (idx + (forward ? 1 : -1) + zones.count) % zones.count
        zones[next].activate()
    }

    private func openSplitPicker(axis: PaneAxis) {
        inputMode = .normal
        guard selectedSession() != nil else { toast = "no session"; return }
        pendingSplitAxis = axis
        modal = .splitPicker(axis)
    }

    /// Пункты модалки: сессии проекта `selected` в порядке сайдбара (спека
    /// «Модалка выбора»). Терминал-зона открывается отдельной командой, не здесь.
    func splitPickerItems(for axis: PaneAxis) -> [SplitPickerItem] {
        SplitPicker.items(projectSessions: orderedSessions().flatMap(\.sessions),
                          occupied: agentPanes,
                          projectRoot: selectedSession().map(sessionRoot))
    }

    /// Выбор в модалке (SplitPickerView).
    func splitPickerChosen(_ item: SplitPickerItem) async {
        let axis = pendingSplitAxis ?? .vertical
        modal = nil
        pendingSplitAxis = nil
        switch item.kind {
        case .session(let name):
            await splitFocusedPane(axis: axis, newSession: name)
        }
    }

    /// Сплит фокусной agent-панели активной View: `newSession` въезжает в её
    /// дерево, своя View растворяется. Фокус и `selected` — в новую панель.
    func splitFocusedPane(axis: PaneAxis, newSession: String) async {
        guard let active = activeView else { return }
        guard active.leaves.count < PaneNode.maxLeaves else {
            toast = "split limit reached"; return
        }
        guard let focused = focusedAgentPane, focused != newSession else { return }
        guard let tree = PaneNode.splitting(active.agentTree, focused: focused,
                                            axis: axis, newSession: newSession)
        else { return }
        await dropView(of: newSession)                 // kills its shell, clears mapping
        mutateForView(active.id, persist: false) { $0.agentTree = tree }
        viewOfSession[newSession] = active.id
        persistWorkspaceViews()
        focusPane(newSession)
        await syncPaneAttachments()
    }

    /// Cmd+W: терминал-зона — закрыть (единственное место, где шелл умирает);
    /// agent-панель сплита — вернуть сессию в свою отдельную View; единственная
    /// панель — no-op (спека «Разбор сплита»).
    func closeFocusedPane() {
        if let shell = activeShell, focusedPane == shell {
            closeActiveTerminal()
            return
        }
        guard let active = activeView, active.isSplit,
              let focused = focusedAgentPane, active.leaves.contains(focused) else { return }
        let successor = detachLeaf(focused).successor   // never emptied: isSplit ⇒ ≥2 leaves
        ensureView(for: focused)                        // the closed pane returns as its own view
        persistWorkspaceViews()
        if let successor { focusPane(successor) }
    }

    private func selectedSession() -> Session? {
        sessions.first { $0.name == selected }
    }

    /// The root the inspector operates on: an explicitly selected project wins,
    /// otherwise use the selected session's project root.
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

    public func activateIssues() {
        if inspectorMode != .issues {
            mutateActiveView { $0.inspector = .shown(mode: .issues) }
        }
        // A freshly mounted pane can miss a same-transaction tick change, so
        // defer until SwiftUI has installed its onChange observer.
        Task { @MainActor in self.issueFocusTick += 1 }
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

    public func switchAndDeleteBranch(
        name: String, expectedBranch: String, checkoutBranch: String
    ) async -> String? {
        do {
            try await client.switchAndDeleteBranch(
                name: name,
                expectedBranch: expectedBranch,
                checkoutBranch: checkoutBranch
            )
            return nil
        } catch {
            return errorText(error)
        }
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
        guard let current = rows.firstIndex(where: rowIsCurrent) else {
            activate(rows[0])
            return
        }
        let next = (current + delta % rows.count + rows.count) % rows.count
        activate(rows[next])
    }

    private func jump(to index: Int) {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        activate(rows[min(rows.count - 1, max(0, index))])
    }

    private func selectSession(at index: Int?) {
        guard let index else { return }
        let names = visibleSessionNames()
        guard names.indices.contains(index) else { return }
        Task { await select(names[index]) }
    }

    private func cycleSession(by delta: Int) {
        let names = visibleSessionNames()
        guard !names.isEmpty else { return }
        let current = sessionCycleTarget ?? selected
        let next: String
        if let current, let index = names.firstIndex(of: current) {
            let nextIndex = (index + delta % names.count + names.count) % names.count
            next = names[nextIndex]
        } else {
            next = names[0]
        }
        sessionCycleTarget = next
        guard sessionCycleTask == nil else { return }
        sessionCycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let target = self.sessionCycleTarget {
                await self.select(target)
                if self.sessionCycleTarget == target {
                    self.sessionCycleTarget = nil
                }
            }
            self.sessionCycleTask = nil
        }
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
        persisted.menuBarLimitsEnabled = menuBarLimitsEnabled
        persisted.recents = recents
        persisted.order = order
        persisted.projectOrder = projectOrder
        persisted.showSessions = showSessions
        persisted.showFooter = showFooter
        persisted.showHeader = showHeader
        persisted.sbWidth = sbWidth
        persisted.vimMode = vimMode
        persisted.showLinks = reviewLinks.showLinks
        persisted.linksOnFocus = reviewLinks.linksOnFocus
        persisted.projectNames = projectNames
        persisted.projects = projects
        snapshotWorkspaceViews()
        store.save(persisted)
    }

    private func apply(_ event: DaemonEvent) {
        switch event {
        case let .usageChanged(snapshot):
            usageStore.apply(snapshot)
        case let .sessionAdded(session):
            sessions.removeAll { $0.name == session.name }
            sessions.append(session)
            sessions.sort { $0.created < $1.created }
            // Every visible session belongs to exactly one workspace view.
            // (Hidden shells are linked directly from `spawnShell`'s response.)
            if session.companionOf == nil, session.hidden != true {
                ensureView(for: session.name)
                persistWorkspaceViews()
            }
        case .sessionRemoved(let name):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            modelByName[name] = nil
            repairAfterSessionGone(name)
        case .exited(let name, _):
            // Companions / hidden shells never become recents — not resumable.
            if let s = sessions.first(where: { $0.name == name }),
               s.companionOf == nil, s.hidden != true {
                pushRecent(&recents, RecentSession(name: s.name, dir: s.dir, agent: s.agent,
                                                   resumeCmd: s.resumeCmd,
                                                   stoppedAt: Int64(Date().timeIntervalSince1970),
                                                   branch: s.git?.branch,
                                                   providerId: s.providerId))
                persist()
            }
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            modelByName[name] = nil
            repairAfterSessionGone(name)
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
        case let .createProgress(stage):
            noteCreateProgress(stage)
        }
    }

    /// Latest session-create stage as presentable text. Internal so tests can
    /// drive it without a daemon round-trip; the event loop lands here too.
    public func noteCreateProgress(_ stage: CreateStage) {
        createStage = stage.label
    }

    /// Forget a dead pane's view plumbing; pane focus falls back to selected.
    /// Сессия исчезла (kill или .exited): колонка/узел дерева чинятся
    /// автоматически, фокус — панель-наследник (спека «Kill и смерть сессии»).
    private func repairAfterSessionGone(_ name: String) {
        // A hidden shell that died: just close its view's terminal zone.
        if let owner = views.first(where: { $0.value.terminal?.shellSession == name }) {
            mutateForView(owner.key) { $0.terminal = nil }
        }
        let wasSplitLeaf = viewForSession(name)?.isSplit == true
        let successor = removeSessionFromView(name)
        if selected == name {
            selected = nil
            if wasSplitLeaf, let successor { focusPane(successor) }
        }
        dropPaneState(name)
    }

    private func dropPaneState(_ name: String) {
        outputSinks[name] = nil
        outputBuffers[name] = nil
        terminalCommands[name] = nil
        attachedNames.remove(name)
        viewMountedSinceAttach.remove(name)
        if focusedPane == name { focusedPane = selected }
    }

    func errorText(_ error: Error) -> String {
        if case let IPCClientError.daemonError(code, message) = error {
            return "\(code): \(message)"
        }
        return "\(error)"
    }
}
