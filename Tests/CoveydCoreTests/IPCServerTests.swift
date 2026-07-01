import XCTest
@testable import CoveydCore
import CoveyKit

final class FakeSink: ClientSink {
    let id: Int
    private let lock = NSLock()
    private var messages: [ServerMessage] = []
    init(id: Int) { self.id = id }
    func send(_ message: ServerMessage) { lock.lock(); messages.append(message); lock.unlock() }
    var captured: [ServerMessage] { lock.lock(); defer { lock.unlock() }; return messages }
}

final class IPCServerTests: XCTestCase {
    private func waitUntil(_ cond: @escaping () -> Bool, _ desc: String) {
        let exp = expectation(description: desc)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { if cond() { timer.cancel(); exp.fulfill() } }
        timer.resume()
        wait(for: [exp], timeout: 5)
    }

    func testCreateReturnsSessionAndBroadcastsAdded() {
        let server = IPCServer(registry: SessionRegistry(clock: { 1 }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 10, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1")), from: sink)
        waitUntil({ sink.captured.contains { if case .response(10, .session) = $0 { return true }; return false } }, "create response")
        waitUntil({ sink.captured.contains { if case .event(.sessionAdded) = $0 { return true }; return false } }, "added event")
        server.handle(Request(id: 11, op: .kill(name: "s1")), from: sink)
    }

    func testUnknownNameReturnsNotFound() {
        let server = IPCServer(registry: SessionRegistry())
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 5, op: .kill(name: "ghost")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(5, .error(let code, _)) = $0 { return code == "notFound" }; return false
        } }, "notFound error")
    }

    func testAttachStreamsBackfillAndLiveOutput() {
        let server = IPCServer(registry: SessionRegistry())
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1")), from: sink)
        server.handle(Request(id: 2, op: .attach(name: "s1", sinceSeq: nil)), from: sink)
        server.handle(Request(id: 3, op: .input(name: "s1", bytesB64: Data("ping\n".utf8).base64EncodedString())), from: sink)
        waitUntil({ sink.captured.contains {
            if case .event(.output(_, _, let b64)) = $0,
               let d = Data(base64Encoded: b64) { return String(decoding: d, as: UTF8.self).contains("ping") }
            return false
        } }, "live output")
        server.handle(Request(id: 4, op: .kill(name: "s1")), from: sink)
    }
}
