import XCTest
@testable import CoveydCore
import CoveyKit

final class EndToEndTests: XCTestCase {
    func testCreateAttachInputOutputKill() throws {
        let path = "\(NSTemporaryDirectory())covey-e2e-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let registry = SessionRegistry()
        let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        let ipc = IPCServer(registry: registry, monitor: monitor)
        let server = SocketServer(path: path)
        server.onAccept = { conn in
            ipc.register(conn)
            conn.onRequest = { req, c in ipc.handle(req, from: c) }
            conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
            conn.onClose = { c in ipc.unregister(c) }
            conn.start()
        }
        try server.start()
        defer { server.stop() }

        let client = IPCTestClient(path: path)
        defer { client.close() }

        func decode(_ s: String) throws -> ServerMessage {
            try NDJSON.decoder.decode(ServerMessage.self, from: Data(s.utf8))
        }

        client.sendLine(#"{"id":1,"op":{"create":{"dir":"/usr","agent":"sh","argv":["/bin/cat"],"name":"s1"}}}"#)
        // create response + sessionAdded event arrive (order not guaranteed); read until we see the response.
        var sawCreate = false
        for _ in 0..<4 {
            if case .response(1, .session) = try decode(client.readLine()) { sawCreate = true; break }
        }
        XCTAssertTrue(sawCreate)

        client.sendLine(#"{"id":2,"op":{"attach":{"name":"s1"}}}"#)
        client.sendLine(#"{"id":3,"op":{"input":{"name":"s1","bytesB64":"cGluZwo="}}}"#)  // "ping\n"

        var sawPing = false
        for _ in 0..<10 {
            if case .event(.output(_, _, let b64)) = try decode(client.readLine()),
               let d = Data(base64Encoded: b64),
               String(decoding: d, as: UTF8.self).contains("ping") { sawPing = true; break }
        }
        XCTAssertTrue(sawPing)

        client.sendLine(#"{"id":9,"op":{"kill":{"name":"s1"}}}"#)
    }
}
