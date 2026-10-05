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
        let resized = await eventually { model.resizesSent > 0 }
        XCTAssertTrue(resized, "precondition: the counter sees resizes")
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

        await model.leaveReview()
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

    private static func contents(of view: CoveyTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).map {
            terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) ?? ""
        }.joined(separator: "\n")
    }

    /// The spec's acceptance check, in the full window: Review shows over the
    /// sessions without a resize or a remount; every terminal is hidden (so
    /// AppKit draws none) with its sampler stopped, while the agent's output
    /// keeps reaching its buffer.
    func testSwitchingModesInTheWindowLeavesTheAgentUntouched() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // Created through the client: only then does live output flow.
        await model.create(dir: "/tmp", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = try XCTUnwrap(model.sessions.first?.name)
        defer { daemon.registry.kill(name: name) }
        await model.select(name)
        _ = ReviewFixture(model)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: ContentView(model: model))
        window.contentView = root
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let mounted = await eventually { self.terminalViews(in: root).count == 1 }
        XCTAssertTrue(mounted)
        let resized = await eventually { model.resizesSent > 0 }
        XCTAssertTrue(resized, "precondition: the counter sees resizes")
        await settle(root)
        let pane = try XCTUnwrap(terminalViews(in: root).first)
        let before = (lease: lease(of: pane), frame: pane.frame, resizes: model.resizesSent)
        XCTAssertTrue(views(CanvasScrollMonitor.MonitorView.self, in: root).isEmpty)

        await model.toggleReview()
        let shown = await eventually {
            self.views(CanvasScrollMonitor.MonitorView.self, in: root).count == 1
        }
        XCTAssertTrue(shown, "the Review canvas is in the window")
        for terminal in terminalViews(in: root) {
            XCTAssertTrue(terminal.isParked && terminal.isHidden, "every terminal is hidden")
            XCTAssertFalse(terminal.isStateSamplerRunning, "no sampler behind Review")
        }
        await model.sendInput(Array("tick-in-review\n".utf8), to: name)
        let arrived = await eventually { Self.contents(of: pane).contains("tick-in-review") }
        XCTAssertTrue(arrived, "output keeps flowing into the hidden terminal")
        await settle(root)

        await model.toggleReview()
        let hidden = await eventually {
            self.views(CanvasScrollMonitor.MonitorView.self, in: root).isEmpty
        }
        XCTAssertTrue(hidden, "back on the sessions, Review is gone")
        for terminal in terminalViews(in: root) {
            XCTAssertFalse(terminal.isParked || terminal.isHidden, "every terminal is back")
            XCTAssertTrue(terminal.isStateSamplerRunning)
        }
        await settle(root)

        XCTAssertIdentical(terminalViews(in: root).first, pane, "no remount")
        XCTAssertEqual(lease(of: pane), before.lease)
        XCTAssertEqual(pane.frame, before.frame, "the workspace kept its size")
        XCTAssertEqual(model.resizesSent, before.resizes, "a mode switch sends no resize")
    }

    // MARK: - The review's life in the window

    private func mount(_ model: AppModel) -> (window: NSWindow, root: NSHostingView<ContentView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSHostingView(rootView: ContentView(model: model))
        window.contentView = root
        window.orderFront(nil)
        return (window, root)
    }

    private func reviewIsShown(in root: NSView) -> Bool {
        views(CanvasScrollMonitor.MonitorView.self, in: root).count == 1
    }

    /// The window's occlusion is what tells the review to stop polling: the
    /// notification of the main window (and only of it) reaches the model.
    func testTheMainWindowsOcclusionDrivesTheReviewsVisibility() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = ReviewFixture(model)
        let (window, root) = mount(model)
        defer { window.orderOut(nil) }
        await model.openReview(ReviewOpening(worktree: "/tmp", projectRoot: "/tmp", originSession: nil))
        let review = try XCTUnwrap(model.review)
        let shown = await eventually { self.reviewIsShown(in: root) }
        XCTAssertTrue(shown)
        await settle(root)

        // Whatever this machine reports, start from the opposite so only the
        // notification can bring the model to the truth.
        let occluded = !window.occlusionState.contains(.visible)
        model.setMainWindowOccluded(!occluded)
        XCTAssertEqual(review.isVisible, occluded, "precondition: the model disagrees with the window")
        let followed = await eventually {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification,
                                            object: window)
            return model.mainWindowOccluded == occluded
        }
        XCTAssertTrue(followed, "the main window's occlusion reaches the model")
        XCTAssertEqual(review.isVisible, !occluded, "and the review's visibility follows it")

        model.setMainWindowOccluded(!occluded)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
        XCTAssertEqual(model.mainWindowOccluded, !occluded, "another window's occlusion is not the main window's")
    }

    /// Only the review on screen polls git: a replaced review's loop is
    /// cancelled (it would otherwise poll a dead worktree for ever, since its
    /// `isVisible` never turns false), and back on the sessions nothing polls.
    func testOnlyTheReviewOnScreenPollsGit() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        let fixture = ReviewFixture(model)
        let (window, root) = mount(model)
        defer { window.orderOut(nil) }
        await settle(root)
        // The window of a headless run may report itself occluded.
        model.setMainWindowOccluded(false)

        await model.openReview(ReviewOpening(worktree: "/tmp", projectRoot: "/tmp", originSession: nil))
        let firstShown = await eventually { self.reviewIsShown(in: root) }
        XCTAssertTrue(firstShown)
        await model.openReview(ReviewOpening(worktree: "/usr", projectRoot: "/usr", originSession: nil))
        XCTAssertEqual(fixture.built.map(\.worktree), ["/tmp", "/usr"], "the second review replaced the first")
        let secondShown = await eventually { self.reviewIsShown(in: root) }
        XCTAssertTrue(secondShown)
        let polled = fixture.git.fingerprintWorktrees.count

        // The poll delay is 3 s: one round of polls falls inside this wait.
        try await Task.sleep(for: .seconds(3.7))
        XCTAssertEqual(Array(fixture.git.fingerprintWorktrees.dropFirst(polled)), ["/usr"],
                       "only the review on screen polls, and it does")

        await model.leaveReview()
        let gone = await eventually { self.views(CanvasScrollMonitor.MonitorView.self, in: root).isEmpty }
        XCTAssertTrue(gone)
        let atLeave = fixture.git.fingerprintCalls
        try await Task.sleep(for: .seconds(3.7))
        XCTAssertEqual(fixture.git.fingerprintCalls, atLeave, "no git polling behind the sessions")
    }
}
