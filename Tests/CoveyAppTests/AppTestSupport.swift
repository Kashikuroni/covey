import Foundation
import XCTest
@testable import covey
import CoveyKit
import CoveydCore

/// In-process daemon stack on a temp socket path (deliberate copy of the
/// CoveyKitTests harness — test targets cannot import each other).
final class TestDaemon {
    let path: String
    let registry: SessionRegistry
    let monitor: StatusMonitor
    var gitMonitor: GitMonitor!
    var modelMonitor: ModelMonitor!
    var traceMonitor: TraceMonitor!
    let traceStore: TraceStore
    /// Временная pm.db тестового демона (удаляется в stop).
    let pmDBPath: String
    /// Fake ~/.claude/projects for transcript fixtures.
    let modelRoot: String
    let traceRoot: String
    let ipc: IPCServer
    @MainActor var usageMonitor: UsageMonitor?

    @MainActor
    func attachUsageMonitor(_ monitor: UsageMonitor) {
        usageMonitor?.stop()
        usageMonitor = monitor
        ipc.attachUsageMonitor(monitor)
    }
    private let server: SocketServer

    init(persisted: [SessionMeta] = []) throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        modelRoot = "\(NSTemporaryDirectory())covey-app-models-\(UInt32.random(in: 0..<UInt32.max))"
        traceRoot = "\(NSTemporaryDirectory())covey-app-traces-\(UInt32.random(in: 0..<UInt32.max))"
        let registry = SessionRegistry(persisted: persisted)
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        gitMonitor = GitMonitor(snapshot: { registry.list().map { ($0.name, $0.dir) } })
        modelMonitor = ModelMonitor(projectsRoot: modelRoot, snapshot: {
            registry.list().map { ($0.name, $0.cwd, $0.agent, $0.created, $0.resumeCmd) }
        })
        let traceStore = TraceStore(root: traceRoot)
        self.traceStore = traceStore
        traceMonitor = TraceMonitor(store: traceStore, projectsRoot: modelRoot, snapshot: {
            registry.list().map { ($0.name, $0.cwd, $0.agent, $0.created, $0.resumeCmd) }
        })
        // PM Foundation: тот же стек, что coveyd/main — на временной pm.db.
        let pmDB = try PMDB(path: "\(NSTemporaryDirectory())covey-app-pm-\(UInt32.random(in: 0..<UInt32.max)).db")
        self.pmDBPath = pmDB.path
        let projectsStore = ProjectStore(db: pmDB)
        let tasksStore = TaskStore(db: pmDB)
        let bindingService = BindingService(db: pmDB, taskStore: tasksStore)
        let rollupService = RollupService(
            db: pmDB, loadBuckets: { [] },
            loadBindings: { (try? bindingService.openBindings()) ?? [] },
            externalKeys: { [:] },
            projectOfSession: { name in
                guard let s = registry.get(name: name) else { return nil }
                return projectsStore.projectID(forSessionRoot: pmSessionRoot(s))
            })
        let pmService = PMService(db: pmDB, projects: projectsStore, tasks: tasksStore,
                                  bindings: bindingService, rollups: rollupService,
                                  analytics: AnalyticsQuery(db: pmDB, prices: []),
                                  now: { Int64(Date().timeIntervalSince1970) })
        pmService.start(liveSessions: registry.list().map(\.name), statuses: [:])
        ipc = IPCServer(registry: registry, monitor: monitor, gitMonitor: gitMonitor,
                        modelMonitor: modelMonitor, traceMonitor: traceMonitor,
                        traceStore: traceStore, pm: pmService)
        server = SocketServer(path: path)
        let ipc = self.ipc
        server.onAccept = { conn in
            ipc.register(conn)
            conn.onRequest = { req, c in ipc.handle(req, from: c) }
            conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
            conn.onClose = { c in ipc.unregister(c) }
            conn.start()
        }
        try server.start()
    }

    func stop() {
        Task { @MainActor in self.usageMonitor?.stop() }
        server.stop()
        try? FileManager.default.removeItem(atPath: modelRoot)
        try? FileManager.default.removeItem(atPath: traceRoot)
        try? FileManager.default.removeItem(atPath: pmDBPath)
    }
}

extension XCTestCase {
    /// Model + the client it talks through (kept for close()-driven tests).
    @MainActor
    func makeModel(_ daemon: TestDaemon, seed: PersistedState? = nil) throws -> (AppModel, IPCClient) {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        let path = daemon.path
        let statePath = "\(NSTemporaryDirectory())covey-model-\(UInt32.random(in: 0..<UInt32.max)).json"
        if let seed {
            let s = StateStore(path: statePath, debounce: 0)
            s.save(seed); s.flush()   // synchronous write before the model loads it
        }
        let model = AppModel(
            client: client,
            makeClient: { let c = IPCClient(path: path); try c.connect(); return c },
            store: StateStore(path: statePath, debounce: 0.05))
        return (model, client)
    }

    /// Polls a MainActor condition every 20 ms until true or timeout.
    func eventually(timeout: TimeInterval = 5,
                    _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: cond) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
