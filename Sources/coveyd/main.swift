import Foundation
import CoveyKit
import CoveydCore

// A Finder-spawned daemon (Covey.app bundle) inherits the bare system PATH,
// where ~/.local/bin and Homebrew binaries don't resolve — every agent
// session would die instantly with exit 127. Children inherit this env.
setenv("PATH", enrichedPATH(ProcessInfo.processInfo.environment["PATH"],
                            home: NSHomeDirectory()), 1)
// Same Finder problem for terminal capabilities: children probe TERM /
// COLORTERM / LANG, and a bare environment demotes TUIs to monochrome.
for (key, value) in terminalEnvDefaults(ProcessInfo.processInfo.environment) {
    setenv(key, value, 0)
}

// Resolve the state root (~/.covey; COVEY_HOME relocates it for a dev instance)
let dir = URL(fileURLWithPath: CoveyPaths.root, isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let socketPath = CoveyPaths.socketPath
// Pidfile next to the socket: `make dev-stop` (and humans) can find THIS
// daemon without guessing which coveyd owns which state root.
let pidPath = CoveyPaths.path("coveyd.pid")

// Single-instance: if an existing socket accepts a connection, another daemon is alive.
if FileManager.default.fileExists(atPath: socketPath) {
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    _ = socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathSize) {
                strlcpy($0, src, pathSize)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let alive = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } == 0
    }
    close(probe)
    if alive {
        FileHandle.standardError.write(Data("coveyd: already running at \(socketPath)\n".utf8))
        exit(1)
    }
    unlink(socketPath)   // stale socket
}

let registryStore = RegistryStore(path: dir.appendingPathComponent("registry.json").path)
let registry = SessionRegistry(persisted: registryStore.load(),
                               onPersist: { registryStore.save($0) })
let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
let gitMonitor = GitMonitor(snapshot: { registry.list().map { ($0.name, $0.dir) } })
let modelMonitor = ModelMonitor(snapshot: {
    registry.list().map { ($0.name, $0.cwd, $0.agent, $0.created, $0.resumeCmd) }
})
let traceStore = TraceStore()
let traceMonitor = TraceMonitor(store: traceStore, snapshot: {
    registry.list().map { ($0.name, $0.cwd, $0.agent, $0.created, $0.resumeCmd) }
})
// PM Foundation (Этап 0, spec pm-design): SQLite-домен проектов/задач/аналитики.
let pmDB: PMDB
do {
    pmDB = try PMDB(path: dir.appendingPathComponent("pm.db").path)
} catch {
    FileHandle.standardError.write(Data("coveyd: pm.db unrecoverable: \(error)\n".utf8))
    exit(1)
}
let projectsStore = ProjectStore(db: pmDB)
let tasksStore = TaskStore(db: pmDB)
let usageSamplesPath = dir.appendingPathComponent("usage-samples.json").path
let bindingService = BindingService(
    db: pmDB, taskStore: tasksStore,
    createSession: { dir, _ in
        // Тот же путь, что form-create в IPCServer: git-IO вне очереди реестра.
        let spec = CreateSpec(name: nil, dir: dir, agent: "claude", terminal: false,
                              worktree: nil, model: nil, effort: nil, resume: nil, hidden: false)
        let prepared = try CreateService.prepare(spec, progress: { _ in })
        return try registry.create(dir: prepared.finalDir, agent: prepared.label,
                                   argv: prepared.argv, name: nil,
                                   worktreeRepo: prepared.worktreeRepo,
                                   resumeCmd: prepared.resumeCmd,
                                   companionOf: nil, env: nil, providerId: nil, hidden: false)
    },
    writePrompt: { name, bytes in registry.write(name: name, bytes: bytes) })
let rollupService = RollupService(
    db: pmDB,
    loadBuckets: { QuotaSampleStore(path: usageSamplesPath).buckets },
    loadBindings: { (try? bindingService.allBindings()) ?? [] },
    externalKeys: { (try? bindingService.externalSessionMap()) ?? [:] },
    projectOfSession: { name in
        guard let s = registry.get(name: name) else { return nil }
        return projectsStore.projectID(forSessionRoot: pmSessionRoot(s))
    })
let pmService = PMService(db: pmDB, projects: projectsStore, tasks: tasksStore,
                          bindings: bindingService, rollups: rollupService,
                          analytics: AnalyticsQuery(db: pmDB,
                                                    prices: PMPrices.loadBundled() ?? []),
                          resolveExternal: { session in
                              ClaudeTranscript.sessionUUID(resumeCmd: session.resumeCmd)
                          },
                          sessionByName: { name in registry.get(name: name) },
                          recoveryNote: pmDB.recoveryNote,
                          now: { Int64(Date().timeIntervalSince1970) })
if let note = pmDB.recoveryNote {
    // Потеря pm.db обязана быть видимой (spec §11): диагностика в лог + событие
    // pm.recovered GUI превратит в toast.
    FileHandle.standardError.write(Data("coveyd: PM DATABASE RECOVERED FRESH: \(note)\n".utf8))
    try? "\(note)".write(toFile: CoveyPaths.path("pm-recovery.log"), atomically: true,
                         encoding: .utf8)
}
// Одноразовая миграция projects/projectNames/projectOrder из state.json (spec §10).
if let stateData = try? Data(contentsOf: URL(fileURLWithPath: dir.appendingPathComponent("state.json").path)),
   let state = try? JSONDecoder().decode(PersistedState.self, from: stateData) {
    _ = try? projectsStore.seed(from: state, now: Int64(Date().timeIntervalSince1970))
}
pmService.start(liveSessions: registry.list().map(\.name),
                statuses: monitor.currentStatuses())
let ipc = IPCServer(registry: registry, monitor: monitor, gitMonitor: gitMonitor,
                    modelMonitor: modelMonitor, traceMonitor: traceMonitor,
                    traceStore: traceStore, pm: pmService)
let usageMonitor = MainActor.assumeIsolated {
    // Прогнозная аналитика: один стор/агрегатор/актор на оба провайдера.
    let forecastStore = QuotaSampleStore(path: dir.appendingPathComponent("usage-samples.json").path)
    let forecastAggregator = TokenAggregator(buckets: forecastStore.buckets)
    // Провайдер-нейтральные идентичности реестра: для Claude — uuid
    // транскрипта, для Codex — nil (роллаут матчуется по cwd/созданию).
    let forecastSessions: () -> [ForecastSessionIdentity] = {
        registry.list().map { s in
            ForecastSessionIdentity(
                sourceID: ClaudeTranscript.sessionUUID(resumeCmd: s.resumeCmd),
                name: s.name, cwd: s.cwd, agent: s.agent,
                created: s.created, providerID: s.providerId)
        }
    }
    let cfg = CoveyConfig.load()
    let glmConfig = GLMForecastConfig(
        includeExternal: cfg.glmForecast?.includeExternal ?? true,
        marginPercent: cfg.glmForecast?.marginPercent ?? 15,
        imminentMinutes: cfg.glmForecast?.imminentMinutes ?? 20)
    let claudeWatcher = TranscriptWatcher(
        projectsRoot: NSHomeDirectory() + "/.claude/projects",
        aggregator: forecastAggregator, store: forecastStore,
        includeExternal: glmConfig.includeExternal)
    let codexWatcher = CodexTranscriptWatcher(
        sessionsRoot: NSHomeDirectory() + "/.codex/sessions",
        aggregator: forecastAggregator, store: forecastStore,
        includeExternal: glmConfig.includeExternal)
    let analyticsMonitor = ForecastAnalyticsMonitor(store: forecastStore,
                                                    aggregator: forecastAggregator,
                                                    claudeWatcher: claudeWatcher,
                                                    codexWatcher: codexWatcher,
                                                    glmConfig: glmConfig,
                                                    codexConfig: CodexForecastConfig(
                                                        marginPercent: glmConfig.marginPercent))
    let usage = UsageMonitor(path: dir.appendingPathComponent("usage.json").path,
                             legacyPath: dir.appendingPathComponent("state.json").path,
                             forecastMonitor: analyticsMonitor,
                             forecastSessions: forecastSessions)
    ipc.attachUsageMonitor(usage)
    return usage
}
let server = SocketServer(path: socketPath)
server.onAccept = { conn in
    ipc.register(conn)
    conn.onRequest = { req, c in ipc.handle(req, from: c) }
    conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
    conn.onClose = { c in ipc.unregister(c) }
    conn.start()
}

// Cleanup the socket file on termination. A signal(2) handler must be a context-free
// C function, so use DispatchSource signal sources (their closures may capture).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let onSignal: () -> Void = {
    MainActor.assumeIsolated { usageMonitor.stop() }
    unlink(socketPath)
    unlink(pidPath)
    exit(0)
}
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
termSource.setEventHandler(handler: onSignal)
intSource.setEventHandler(handler: onSignal)
termSource.resume()
intSource.resume()

do {
    try server.start()
    try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("coveyd: listening at \(socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("coveyd: failed to start: \(error)\n".utf8))
    exit(1)
}

MainActor.assumeIsolated { usageMonitor.start() }
monitor.start()
gitMonitor.start()
modelMonitor.start()
traceStore.prune()   // drop traces older than the 7-day retention window
traceMonitor.start()

dispatchMain()
