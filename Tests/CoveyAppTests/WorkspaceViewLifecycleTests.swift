import XCTest
@testable import covey
import CoveyKit

@MainActor final class WorkspaceViewLifecycleTests: XCTestCase {
    /// Deterministic "view-1", "view-2", … ids.
    func counter() -> () -> ViewID {
        var n = 0
        return { n += 1; return "view-\(n)" }
    }

    func testNewSessionGetsItsOwnSingleView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newViewID = counter()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.sessions.count == 1 }
        XCTAssertEqual(model.viewOfSession["a"], "view-1")
        XCTAssertEqual(model.views["view-1"]?.leaves, ["a"])
        await model.select("a")
        XCTAssertEqual(model.activeView?.id, "view-1")
    }

    /// Two sessions, "a" selected, then split "b" into it.
    func splitAB(_ daemon: TestDaemon) async throws -> AppModel {
        let (model, _) = try makeModel(daemon)
        model.newViewID = counter()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 && model.viewOfSession.count == 2 }
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")
        return model
    }

    func testSplitMergesViewsAndDeletesSource() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await splitAB(daemon)
        let vid = try XCTUnwrap(model.viewOfSession["a"])
        XCTAssertEqual(model.viewOfSession["b"], vid)
        XCTAssertEqual(model.views[vid]?.leaves.sorted(), ["a", "b"])
        XCTAssertEqual(model.views.count, 1, "b's original view is gone")
        XCTAssertEqual(model.selected, "b")
        XCTAssertEqual(model.activeView?.leaves.sorted(), ["a", "b"])
    }

    func testClosePaneReturnsSessionToItsOwnView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await splitAB(daemon)   // active view {a,b}, focus b
        model.closeFocusedPane()

        let aView = try XCTUnwrap(model.viewOfSession["a"])
        let bView = try XCTUnwrap(model.viewOfSession["b"])
        XCTAssertNotEqual(aView, bView)
        XCTAssertEqual(model.views[aView]?.leaves, ["a"])
        XCTAssertEqual(model.views[bView]?.leaves, ["b"])
        XCTAssertEqual(model.selected, "a", "focus falls to the successor")
    }

    func testSessionDeathRemovesLeafButKeepsMultiLeafView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let model = try await splitAB(daemon)
        let vid = try XCTUnwrap(model.viewOfSession["a"])
        _ = try daemon.registry.kill(name: "b")
        _ = await eventually { model.sessions.count == 1 }
        XCTAssertEqual(model.views[vid]?.leaves, ["a"])
        XCTAssertNil(model.viewOfSession["b"])
        XCTAssertEqual(model.views.count, 1)
    }

    func testLastLeafDeathDeletesView() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newViewID = counter()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.viewOfSession["a"] != nil }
        let vid = try XCTUnwrap(model.viewOfSession["a"])
        _ = try daemon.registry.kill(name: "a")
        _ = await eventually { model.sessions.isEmpty }
        XCTAssertNil(model.views[vid])
        XCTAssertTrue(model.viewOfSession.isEmpty)
    }

    func testRenameMovesViewMapping() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newViewID = counter()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = await eventually { model.viewOfSession["a"] != nil }
        await model.select("a")
        await model.rename("a", to: "a2")
        _ = await eventually { model.sessions.contains { $0.name == "a2" } }
        XCTAssertNil(model.viewOfSession["a"])
        XCTAssertEqual(model.views["view-1"]?.leaves, ["a2"])
        XCTAssertEqual(model.viewOfSession["a2"], "view-1")
    }

    func testTwoSessionsGetSeparateViews() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        model.newViewID = counter()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "a")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b")
        _ = await eventually { model.sessions.count == 2 }
        XCTAssertEqual(Set(model.viewOfSession.keys), ["a", "b"])
        XCTAssertNotEqual(model.viewOfSession["a"], model.viewOfSession["b"])
    }
}
