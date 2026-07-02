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
    private let ipc: IPCServer
    private let server: SocketServer

    init() throws {
        path = "\(NSTemporaryDirectory())covey-app-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        ipc = IPCServer(registry: registry, monitor: monitor)
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

    func stop() { server.stop() }
}

extension XCTestCase {
    /// Model + the client it talks through (kept for close()-driven tests).
    @MainActor
    func makeModel(_ daemon: TestDaemon) throws -> (AppModel, IPCClient) {
        let client = IPCClient(path: daemon.path)
        try client.connect()
        let path = daemon.path
        let model = AppModel(client: client, makeClient: {
            let c = IPCClient(path: path)
            try c.connect()
            return c
        })
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
