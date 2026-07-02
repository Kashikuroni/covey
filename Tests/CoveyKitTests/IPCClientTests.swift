import XCTest
@testable import CoveyKit
import CoveydCore

final class IPCClientTests: XCTestCase {
    func testRequestBeforeConnectThrowsNotConnected() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        do {
            _ = try await client.list()
            XCTFail("expected notConnected")
        } catch let e as IPCClientError {
            XCTAssertEqual(e, .notConnected)
        }
    }

    func testConnectToMissingSocketThrowsConnectFailed() {
        let client = IPCClient(path: "\(NSTemporaryDirectory())covey-nope.sock")
        do {
            try client.connect()
            XCTFail("expected connectFailed")
        } catch IPCClientError.connectFailed {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testListOnEmptyRegistry() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }
        let (sessions, statuses, lost) = try await client.list()
        XCTAssertEqual(sessions, [])
        XCTAssertEqual(statuses, [:])
        XCTAssertNil(lost)
    }

    func testCreateReturnsSessionAndKillGhostThrowsNotFound() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        let s = try await client.create(dir: "/usr", agent: "sh",
                                        argv: ["/bin/cat"], name: "c1")
        XCTAssertEqual(s.name, "c1")
        try await client.kill(name: "c1")

        do {
            try await client.kill(name: "ghost")
            XCTFail("expected notFound")
        } catch let IPCClientError.daemonError(code, _) {
            XCTAssertEqual(code, "notFound")
        }
    }

    func testAttachInputStreamsOutputEvent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        _ = try await client.create(dir: "/usr", agent: "sh",
                                    argv: ["/bin/cat"], name: "s1")
        try await client.attach(name: "s1")
        try await client.input(name: "s1", bytes: Array("ping\n".utf8))

        let event = await awaitEvent(client) { e in
            if case let .output(_, _, b64) = e, let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self).contains("ping")
            }
            return false
        }
        XCTAssertNotNil(event, "no output event with 'ping' within timeout")
        try await client.kill(name: "s1")
    }

    func testStatusChangedArrivesViaEvents() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }

        _ = try await client.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'pick:\\n  1. yes\\n  2. no\\n'; exec cat"],
            name: "menu")
        // Wait until the daemon-side screen shows the menu, then tick once.
        let ticker = Task { [monitor = daemon.monitor, registry = daemon.registry] in
            while registry.snapshotScreens()["menu"]?.contains("2. no") != true {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            monitor.tick()
        }
        let event = await awaitEvent(client) { e in
            if case .statusChanged("menu", .waiting) = e { return true }
            return false
        }
        ticker.cancel()
        XCTAssertNotNil(event, "no statusChanged(waiting) within timeout")
        try await client.kill(name: "menu")
    }

    func testCloseFailsPendingRequestWithDisconnected() async throws {
        let daemon = try TestDaemon(mute: true)   // accepts, never responds
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()

        let pending = Task { () -> IPCClientError? in
            do { _ = try await client.list(); return nil }
            catch let e as IPCClientError { return e }
            catch { return nil }
        }
        // Give the request a moment to become pending, then close underneath it.
        try await Task.sleep(nanoseconds: 100_000_000)
        client.close()
        let error = await pending.value
        XCTAssertEqual(error, .disconnected)

        // events must be finished: iteration ends immediately.
        let leftover = await awaitEvent(client, timeout: 1) { _ in true }
        XCTAssertNil(leftover)

        // subsequent requests fail fast.
        do {
            _ = try await client.list()
            XCTFail("expected notConnected")
        } catch let e as IPCClientError {
            XCTAssertEqual(e, .notConnected)
        }
    }
}
