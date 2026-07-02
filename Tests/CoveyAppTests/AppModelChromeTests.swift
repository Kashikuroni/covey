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

    @MainActor
    func testInspectorAndVimStatePersistAndLoad() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let path = "\(NSTemporaryDirectory())covey-inspector-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 0.05)
        let client = IPCClient(path: daemon.path); try client.connect()
        let model = AppModel(client: client,
                             makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                             store: store)
        await model.start()
        XCTAssertFalse(model.showInspector)
        XCTAssertEqual(model.sbWidth, 360)
        XCTAssertTrue(model.vimMode, "vim mode is on by default since slice 12")
        model.setShowInspector(true)
        model.setSbWidth(420)
        model.setVimMode(true)
        store.flush()
        let reloaded = store.load()
        XCTAssertEqual(reloaded.showInspector, true)
        XCTAssertEqual(reloaded.sbWidth, 420)
        XCTAssertEqual(reloaded.vimMode, true)
        // A fresh model over the same store loads them back.
        let client2 = IPCClient(path: daemon.path); try client2.connect()
        let model2 = AppModel(client: client2,
                              makeClient: { let c = IPCClient(path: daemon.path); try c.connect(); return c },
                              store: StateStore(path: path, debounce: 0.05))
        await model2.start()
        XCTAssertTrue(model2.showInspector)
        XCTAssertEqual(model2.sbWidth, 420)
        XCTAssertTrue(model2.vimMode)
    }

    @MainActor
    func testSbWidthClampsAndFocusInspector() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.setSbWidth(100)
        XCTAssertEqual(model.sbWidth, 240)
        model.setSbWidth(9000)
        XCTAssertEqual(model.sbWidth, 600)
        model.setFocus(.inspector)
        XCTAssertEqual(model.focus, .inspector)
    }

    @MainActor
    func testApplyNavigationWalksVisibleSessions() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s1")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s2")
        _ = try daemon.registry.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "s3")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 3 }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s2" }
        model.apply(.selectPrev)
        _ = await eventually { model.selected == "s1" }
        model.apply(.selectByNumber(3))
        _ = await eventually { model.selected == "s3" }
        model.apply(.selectFirst)
        _ = await eventually { model.selected == "s1" }
        // filter narrows navigation
        model.setFilter("s3")
        model.apply(.selectNext)
        _ = await eventually { model.selected == "s3" }
        model.setFilter("")
        for s in model.sessions { daemon.registry.kill(name: s.name) }
    }

    @MainActor
    func testApplyModeTransitionsAndModals() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.openLeader)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.leaderDescend(.session))
        XCTAssertEqual(model.inputMode, .leader(.session))
        model.apply(.leaderBack)
        XCTAssertEqual(model.inputMode, .leader(.root))
        model.apply(.closeOverlay)
        XCTAssertEqual(model.inputMode, .normal)
        model.apply(.enterSelectMode)
        XCTAssertEqual(model.inputMode, .selectSession)
        model.apply(.closeOverlay)
        model.apply(.showHelp)
        XCTAssertEqual(model.inputMode, .help)
        model.apply(.closeOverlay)
        model.apply(.newSession(prefillDir: false))
        XCTAssertEqual(model.modal, .newSession)
        model.modal = nil
        model.apply(.toggleTab)
        XCTAssertEqual(model.listTab, .recent)
        model.apply(.toggleTab)
        XCTAssertEqual(model.listTab, .active)
        model.apply(.resizeSplit(3))
        XCTAssertEqual(model.splitPct, 41)   // 38 default + 3
    }

    @MainActor
    func testApplyKillRenameNeedSelection() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.apply(.killSelected)
        XCTAssertNil(model.modal, "no selection — no kill sheet")
        await model.create(dir: "/a", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)
        model.apply(.killSelected)
        XCTAssertEqual(model.modal, .kill(name))
        model.modal = nil
        model.apply(.renameSelected)
        XCTAssertEqual(model.modal, .rename(name))
        model.modal = nil
        await model.kill(name)
    }
}
