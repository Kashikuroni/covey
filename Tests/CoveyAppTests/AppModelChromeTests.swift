import XCTest
@testable import covey
import CoveyKit
import Foundation

final class AppModelChromeTests: XCTestCase {
    @MainActor
    func testCountsByStatus() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        // statuses arrive from the daemon poller over time; assert total here and
        // running/waiting counters are derived (0 by default before any tick).
        XCTAssertEqual(model.counts.total, 2)
        for s in model.sessions { await model.kill(s.name) }
    }

    @MainActor
    func testOrderedSessionsRespectsOrder() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        // default order = by created (s1 then s2)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s1", "s2"])
        // move s2 before s1
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(model.orderedSessions().first?.sessions.map(\.name), ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testMoveSessionPersists() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        model.moveSession(inDir: "/a", from: IndexSet(integer: 1), to: 0)
        store.flush()
        XCTAssertEqual(store.load().order, ["s2", "s1"])
        daemon.registry.kill(name: "s1"); daemon.registry.kill(name: "s2")
    }

    @MainActor
    func testShowFlagsPersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-chrome-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        model.setShowFooter(false)
        model.setShowHeader(false)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showFooter, false)
        XCTAssertEqual(reloaded.showHeader, false)
    }

    @MainActor
    func testHistoryModeResetsOnSelect() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.setHistoryMode(true)
        XCTAssertTrue(model.historyMode)
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 2 }
        let other = model.sessions.first { $0.name != name }!.name
        await model.select(other)
        XCTAssertFalse(model.historyMode, "history mode must reset on session switch")
        await model.kill(name); await model.kill(other)
    }
}
