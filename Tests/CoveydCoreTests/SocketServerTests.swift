import XCTest
@testable import CoveydCore
import CoveyKit

final class SocketServerTests: XCTestCase {
    private func tempSocketPath() -> String {
        "\(NSTemporaryDirectory())covey-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }
    
    func testEchoRequestRoundTrip() throws {
        let path = tempSocketPath()
        let server = SocketServer(path: path)
        let connected = expectation(description: "request received")
        server.onAccept = { conn in
            conn.onRequest = { req, c in
                connected.fulfill()
                c.send(.response(id: req.id, result: .ok)) // echo an ok
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }
        
        let client = IPCTestClient(path: path)
        defer { client.close() }
        client.sendLine(#"{"id":7,"op":{"list":{}}}"#)
        wait(for: [connected], timeout: 5)
        
        let reply = client.readLine()
        let msg = try NDJSON.decoder.decode(ServerMessage.self, from: Data(reply.utf8))
        XCTAssertEqual(msg, .response(id: 7, result: .ok))
    }
    
    func testBadRequestReportsId() throws {
        let path = tempSocketPath()
        let server = SocketServer(path: path)
        let bad = expectation(description: "bad request")
        server.onAccept = { conn in
            conn.onBadRequest = { id, _ in
                XCTAssertEqual(id, 9)
                bad.fulfill()
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }
        
        let client = IPCTestClient(path: path)
        defer { client.close() }
        client.sendLine(#"{"id":9,"op":{"bogus":{}}}"#) // valid id, invalid op
        wait(for: [bad], timeout: 5)
    }
}
