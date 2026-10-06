import XCTest
@testable import CoveyKit
import CoveydCore

final class UsageIPCTests: XCTestCase {
    func testUsageProtocolRoundTrips() throws {
        var snapshot = UsageSnapshot()
        snapshot.revision = 12
        snapshot.usage = Usage(fiveHour: UsageWindow(utilization: 42, resetUnix: 123),
                               sevenDay: nil, sevenDaySonnet: nil)
        snapshot.codexUsageEnabled = false
        snapshot.forecastAnalytics = ForecastAnalytics(
            models: [
                GLMModelUsage(model: "gpt-6-sol",
                              window: GLMTokenUsage(input: 100, output: 20, cacheRead: 80),
                              lastHour: GLMTokenUsage(input: 100, output: 20, cacheRead: 80))
            ],
            sessions: [
                ForecastSessionUsage(id: "codex:s1", name: "app", source: .codex,
                                     external: true, active: true, tokensPerHour: 12_000)
            ])
        let message = ServerMessage.event(.usageChanged(snapshot: snapshot))
        XCTAssertEqual(try JSONDecoder().decode(ServerMessage.self,
                       from: JSONEncoder().encode(message)), message)
        let request = Request(id: 1, op: .usageSetEnabled(provider: .codex, enabled: false))
        XCTAssertEqual(try JSONDecoder().decode(Request.self,
                       from: JSONEncoder().encode(request)), request)
    }

    @MainActor
    func testSubscribersShareSettingsAndReconnectSnapshot() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let monitor = UsageMonitor(fetchAccount: { Account(plan: "Pro") },
                                   resolveCodex: { nil })
        defer { monitor.stop() }
        daemon.ipc.attachUsageMonitor(monitor)
        let first = IPCClient(path: daemon.path)
        let second = IPCClient(path: daemon.path)
        let observer = IPCClient(path: daemon.path)
        try first.connect(); try second.connect(); try observer.connect()
        defer { first.close(); second.close(); observer.close() }
        let a = try await first.usageSubscribe()
        let b = try await second.usageSubscribe()
        XCTAssertEqual(a, b)
        let changed = try await first.usageSetEnabled(provider: .claude, enabled: false)
        XCTAssertFalse(changed.claudeUsageEnabled)
        let event = await awaitEvent(second) {
            if case .usageChanged(let snapshot) = $0 { return !snapshot.claudeUsageEnabled }
            return false
        }
        XCTAssertEqual(event, .usageChanged(snapshot: changed))
        let unsolicited = await awaitEvent(observer, timeout: 0.1) {
            if case .usageChanged = $0 { return true }; return false
        }
        XCTAssertNil(unsolicited)
        first.close(); second.close()
        try monitor.setEnabled(.claude, enabled: true)
        await monitor.refresh(.claude)
        let reconnected = IPCClient(path: daemon.path)
        try reconnected.connect()
        defer { reconnected.close() }
        let latest = try await reconnected.usageSubscribe()
        XCTAssertTrue(latest.claudeUsageEnabled)
        XCTAssertEqual(latest.plan, "Pro")
        XCTAssertGreaterThan(latest.revision, changed.revision)
    }

    @MainActor
    func testAbsentCollectorReturnsErrorWithoutBreakingSessions() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let client = IPCClient(path: daemon.path)
        try client.connect()
        defer { client.close() }
        do {
            _ = try await client.usageSubscribe()
            XCTFail("Expected an unavailable collector error")
        } catch let IPCClientError.daemonError(code, _) {
            XCTAssertEqual(code, "usageUnavailable")
        }
        let result = try await client.list()
        XCTAssertTrue(result.sessions.isEmpty)
    }
}
