import XCTest
@testable import CoveyKit
import CoveydCore

final class DaemonLauncherTests: XCTestCase {
    func testAliveSocketIsNoOp() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        // binaryPath is bogus: if ensureDaemon tried to spawn, it would throw.
        try DaemonLauncher.ensureDaemon(socketPath: daemon.path,
                                        binaryPath: "/nonexistent-daemon",
                                        timeout: 0.3)
    }

    func testDeadSocketTimesOut() {
        let path = "\(NSTemporaryDirectory())covey-dead-\(UInt32.random(in: 0..<UInt32.max)).sock"
        do {
            // /usr/bin/false exits immediately and never creates the socket.
            try DaemonLauncher.ensureDaemon(socketPath: path,
                                            binaryPath: "/usr/bin/false",
                                            timeout: 0.3)
            XCTFail("expected connectFailed")
        } catch IPCClientError.connectFailed {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // Real-daemon smoke (DoD §7.2-3). Run manually:
    //   COVEY_SMOKE=1 xcrun xctest -XCTest CoveyKitTests.DaemonLauncherTests \
    //     .build/arm64-apple-macosx/debug/coveyPackageTests.xctest
    func testSmokeRealDaemonRoundTripAndKill() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COVEY_SMOKE"] == "1",
                          "smoke test; set COVEY_SMOKE=1 to run")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaemonLauncherTests.swift
            .deletingLastPathComponent()   // CoveyKitTests
            .deletingLastPathComponent()   // Tests
        let binary = root.appendingPathComponent(".build/debug/coveyd").path
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".covey/coveyd.sock").path

        try DaemonLauncher.ensureDaemon(socketPath: socket, binaryPath: binary)
        let client = IPCClient(path: socket)
        try client.connect()

        let s = try await client.create(dir: "/usr", agent: "sh",
                                        argv: ["/bin/cat"], name: "smoke")
        XCTAssertEqual(s.name, "smoke")
        try await client.attach(name: "smoke")
        try await client.input(name: "smoke", bytes: Array("ping\n".utf8))
        let output = await awaitEvent(client) { e in
            if case let .output(_, _, b64) = e, let d = Data(base64Encoded: b64) {
                return String(decoding: d, as: UTF8.self).contains("ping")
            }
            return false
        }
        XCTAssertNotNil(output)

        // kill -9 the daemon: pending request fails, events stream ends.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-f", binary]
        try killer.run()
        killer.waitUntilExit()

        let ended = await awaitEvent(client, timeout: 5) { _ in false }
        XCTAssertNil(ended)   // stream finished (or timed out — finish is the pass)
        do {
            _ = try await client.list()
            XCTFail("expected notConnected or disconnected")
        } catch let e as IPCClientError {
            XCTAssertTrue(e == .notConnected || e == .disconnected)
        }
    }
}
