import Foundation
import XCTest
@testable import CoveyKit
import CoveydCore

/// In-process daemon stack on a temp socket path, for client integration tests.
final class TestDaemon {
    let path: String
    let registry: SessionRegistry
    let monitor: StatusMonitor
    private let ipc: IPCServer
    private let server: SocketServer

    /// `mute: true` accepts connections but wires no handlers, so requests
    /// get no responses — for pending/disconnect tests.
    init(mute: Bool = false) throws {
        path = "\(NSTemporaryDirectory())covey-kit-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        self.registry = registry
        monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        ipc = IPCServer(registry: registry, monitor: monitor)
        server = SocketServer(path: path)
        let ipc = self.ipc
        server.onAccept = { conn in
            guard !mute else { conn.start(); return }
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
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// First event matching `pred`, or nil after `timeout`. Single consumer:
    /// do not run two of these against the same client concurrently.
    func awaitEvent(_ client: IPCClient, timeout: TimeInterval = 5,
                    where pred: @escaping (DaemonEvent) -> Bool) async -> DaemonEvent? {
        let consumer = Task { () -> DaemonEvent? in
            for await e in client.events where pred(e) { return e }
            return nil
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            consumer.cancel()
        }
        let result = await consumer.value
        timer.cancel()
        return result
    }
}
