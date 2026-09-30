import XCTest
import SwiftUI
@testable import covey
import CoveyKit

/// Review hides the sessions workspace without touching its terminals:
/// no remount, no resize (an agent's SIGWINCH); every terminal is hidden
/// with its sampler stopped until the sessions come back.
@MainActor
final class ReviewModeWindowTests: XCTestCase {
    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func terminalViews(in root: NSView) -> [CoveyTerminalView] {
        views(CoveyTerminalView.self, in: root)
    }

    private func lease(of view: CoveyTerminalView) -> TerminalViewLease? {
        (view.terminalDelegate as? TerminalRepresentable.Coordinator)?.lease
    }

    /// Lets queued layout passes and resize tasks run out.
    private func settle(_ root: NSView) async {
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        root.layoutSubtreeIfNeeded()
    }

    func testReviewParksTheAgentPaneWithoutRemountOrResize() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        defer { daemon.registry.kill(name: "agent") }
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        await model.select("agent")
        _ = ReviewFixture(model)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root
        let mounted = await eventually { self.terminalViews(in: root).count == 1 }
        XCTAssertTrue(mounted)
        _ = await eventually { model.resizesSent > 0 }
        await settle(root)
        let pane = try XCTUnwrap(terminalViews(in: root).first)
        let before = (lease: lease(of: pane), frame: pane.frame, resizes: model.resizesSent)
        XCTAssertFalse(pane.isParked)
        model.focusPane("agent")
        XCTAssertIdentical(window.firstResponder, pane, "precondition: the agent has the keyboard")

        XCTAssertTrue(pane.isStateSamplerRunning, "precondition: a pane in a window samples")

        await model.toggleReview()
        let parked = await eventually { pane.isParked }
        XCTAssertTrue(parked, "Review parks the pane")
        XCTAssertTrue(pane.isHidden, "AppKit draws no hidden view")
        XCTAssertFalse(pane.isStateSamplerRunning)
        XCTAssertFalse(window.firstResponder === pane)
        await settle(root)

        model.leaveReview()
        let back = await eventually { !pane.isParked }
        XCTAssertTrue(back)
        XCTAssertFalse(pane.isHidden)
        XCTAssertTrue(pane.isStateSamplerRunning)
        let refocused = await eventually { window.firstResponder === pane }
        XCTAssertTrue(refocused, "back from Review, the agent has the keyboard again")
        await settle(root)

        XCTAssertIdentical(terminalViews(in: root).first, pane, "no remount")
        XCTAssertEqual(lease(of: pane), before.lease)
        XCTAssertEqual(pane.frame, before.frame)
        XCTAssertEqual(model.resizesSent, before.resizes, "a mode switch sends no resize")
    }
}
