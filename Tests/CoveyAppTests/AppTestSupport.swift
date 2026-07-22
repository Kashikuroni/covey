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
    /// Fake ~/.claude/projects for transcript fixtures.
    let modelRoot: String
    private let ipc: IPCServer
    private let server: SocketServer

    init(persisted: [SessionMeta] = []) throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        modelRoot = "\(NSTemporaryDirectory())covey-app-models-\(UInt32.random(in: 0..<UInt32.max))"
        let registry = SessionRegistry(persisted: persisted)
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        gitMonitor = GitMonitor(snapshot: { registry.list().map { ($0.name, $0.dir) } })
        modelMonitor = ModelMonitor(projectsRoot: modelRoot, snapshot: {
            registry.list().map { ($0.name, $0.cwd, $0.agent, $0.created, $0.resumeCmd) }
        })
        ipc = IPCServer(registry: registry, monitor: monitor, gitMonitor: gitMonitor,
                        modelMonitor: modelMonitor)
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
        server.stop()
        try? FileManager.default.removeItem(atPath: modelRoot)
    }
}

extension XCTestCase {
    /// Model + the client it talks through (kept for close()-driven tests).
    @MainActor
    func makeModel(_ daemon: TestDaemon) throws -> (AppModel, IPCClient) {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        let path = daemon.path
        let statePath = "\(NSTemporaryDirectory())covey-model-\(UInt32.random(in: 0..<UInt32.max)).json"
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
