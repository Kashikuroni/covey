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
    func testCreateReturnsSessionAndBroadcastsAdded() {
        let registry = SessionRegistry(clock: { 1 })
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 10, op: .create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "s1")), from: sink)
        waitUntil({ sink.captured.contains { if case .response(10, .session) = $0 { return true }; return false } }, "create response")
        waitUntil({ sink.captured.contains { if case .event(.sessionAdded) = $0 { return true }; return false } }, "added event")
        server.handle(Request(id: 11, op: .kill(name: "s1")), from: sink)
    }

    func testUnknownNameReturnsNotFound() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 5, op: .kill(name: "ghost")), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(5, .error(let code, _)) = $0 { return code == "notFound" }; return false
        } }, "notFound error")
    }

    func testAttachStreamsBackfillAndLiveOutput() {
        let registry = SessionRegistry()
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
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

    func testTickBroadcastsWaitingAndListCarriesStatuses() {
        let registry = SessionRegistry()
        let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
        let server = IPCServer(registry: registry, monitor: monitor)
        let sink = FakeSink(id: 1)
        server.register(sink)
        // A session whose screen ends in a numbered menu -> waiting.
        server.handle(Request(id: 1, op: .create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")), from: sink)
        waitUntil({ registry.snapshotScreens()["menu"]?.contains("2. no") == true },
                  "menu rendered")
        monitor.tick()
        waitUntil({ sink.captured.contains {
            if case .event(.statusChanged("menu", .waiting)) = $0 { return true }
            return false
        } }, "statusChanged waiting")
        server.handle(Request(id: 2, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .sessions(_, let statuses, _)) = $0 {
                return statuses["menu"] == .waiting
            }
            return false
        } }, "list has statuses")
        server.handle(Request(id: 3, op: .kill(name: "menu")), from: sink)
    }

    func testListCarriesLostAndClearLostRemoves() {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let registry = SessionRegistry(persisted: [meta])
        let server = IPCServer(registry: registry,
                               monitor: StatusMonitor(snapshot: { registry.snapshotScreens() }))
        let sink = FakeSink(id: 1)
        server.register(sink)
        server.handle(Request(id: 1, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(1, .sessions(_, _, let lost)) = $0 { return lost?.map(\.name) == ["old"] }
            return false
        } }, "list carries lost")
        server.handle(Request(id: 2, op: .clearLost), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(2, .ok) = $0 { return true }; return false
        } }, "clearLost acked")
        server.handle(Request(id: 3, op: .list), from: sink)
        waitUntil({ sink.captured.contains {
            if case .response(3, .sessions(_, _, let lost)) = $0 { return lost == nil }
            return false
        } }, "lost cleared")
    }
}
