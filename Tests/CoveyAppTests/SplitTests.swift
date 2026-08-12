import XCTest
@testable import covey
import CoveyKit

@MainActor
final class SplitTests: XCTestCase {
    func testSplitGuardsAndLifecycle() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        // Guard: no selection -> disabled, nothing created.
        model.perform(.splitTerminalVertically)
        XCTAssertEqual(model.commandAvailability(.splitTerminalVertically),
                       .disabled(reason: "No session selected"))
        XCTAssertNil(model.toast)
        XCTAssertTrue(daemon.registry.list().isEmpty)

        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        await model.select("agent")
        XCTAssertEqual(model.focusedPane, "agent")

        model.perform(.splitTerminalVertically)
        let created = await eventually { model.companion(of: "agent") != nil }
        XCTAssertTrue(created)
        XCTAssertEqual(model.companion(of: "agent")?.name, "agent+sh")

        // Companions are invisible to cards, numbers and counts.
        XCTAssertFalse(model.visibleSessionNames().contains("agent+sh"))
        XCTAssertEqual(model.counts.total, 1)
        XCTAssertFalse(model.orderedSessions().flatMap(\.sessions)
            .contains { $0.companionOf != nil })

        // The fresh companion takes the pane focus.
        let focused = await eventually { model.focusedPane == "agent+sh" }
        XCTAssertTrue(focused)

        // A second split request must not create a second companion.
        model.perform(.splitTerminalVertically)
        let grew = await eventually(timeout: 0.6) { daemon.registry.list().count > 2 }
        XCTAssertFalse(grew, "split with a live companion only refocuses")

        // ⌃\ toggles between parent and companion.
        model.apply(.splitFocusToggle)
        XCTAssertEqual(model.focusedPane, "agent")
        model.apply(.splitFocusToggle)
        XCTAssertEqual(model.focusedPane, "agent+sh")

        // Close: the companion dies, the split collapses, focus returns.
        model.perform(.closeTerminalSplit)
        let closed = await eventually { model.companion(of: "agent") == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(model.focusedPane, "agent")
        // The dead shell is not a recent.
        XCTAssertFalse(model.recents.contains { $0.name == "agent+sh" })

        daemon.registry.kill(name: "agent")
    }

    func testSplitAxisPersists() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let statePath = "\(NSTemporaryDirectory())covey-split-\(UInt32.random(in: 0..<UInt32.max)).json"
        let path = daemon.path
        func newModel() throws -> AppModel {
            let client = IPCClient(path: path)
            try client.connect()
            return AppModel(
                client: client,
                makeClient: { let c = IPCClient(path: path); try c.connect(); return c },
                store: StateStore(path: statePath, debounce: 0))
        }
        let model = try newModel()
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                       argv: ["/bin/cat"], name: "agent")
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        await model.select("agent")
        model.perform(.splitTerminalHorizontally)
        XCTAssertEqual(model.splitAxis(for: "agent"), "h")
        XCTAssertEqual(model.splitAxis(for: "other"), "v", "default axis is vertical")

        // The axis survives into a fresh model over the same store.
        let saved = await eventually {
            StateStore(path: statePath).load().splitAxes?["agent"] == "h"
        }
        XCTAssertTrue(saved)
        let model2 = try newModel()
        await model2.start()
        XCTAssertEqual(model2.splitAxis(for: "agent"), "h")

        daemon.registry.kill(name: "agent")
    }
}
