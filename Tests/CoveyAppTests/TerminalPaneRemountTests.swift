import XCTest
import SwiftUI
@testable import covey
import CoveyKit

/// Opening/closing the terminal split switches TerminalPaneView between two
/// structural branches, which remounts the agent's NSView: a fresh emulator
/// that never saw the session's `?1049h`. Without a re-attach (the preamble
/// only flows on attach) the pane drops out of the alternate buffer and
/// wheel routing degrades to `.viewport` — "scroll stops working until the
/// app restarts".
@MainActor
final class TerminalPaneRemountTests: XCTestCase {
    private func terminalViews(in root: NSView) -> [CoveyTerminalView] {
        var found: [CoveyTerminalView] = []
        func walk(_ view: NSView) {
            if let term = view as? CoveyTerminalView { found.append(term) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func altCount(in root: NSView) -> Int {
        terminalViews(in: root)
            .filter { $0.getTerminal().isCurrentBufferAlternate }.count
    }

    func testSplitToggleKeepsAgentAltBufferState() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/usr", agent: "claude",
            argv: ["/bin/sh", "-c",
                   "printf '\\033[?1049h\\033[?1003h\\033[?1006hREADY'; exec cat"],
            name: "agent")
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        _ = await eventually {
            daemon.registry.statePreamble(name: "agent")?.isEmpty == false
        }
        await model.select("agent")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalPaneView(model: model))

        // Single pane: the agent's view replays the attach preamble -> alt.
        let mounted = await eventually {
            window.contentView.map { self.altCount(in: $0) } == 1
        }
        XCTAssertTrue(mounted, "agent pane should reach the alternate buffer")

        // Open the terminal split: the agent view remounts; its fresh
        // emulator must regain the session's alt+mouse state.
        model.apply(.splitVertical)
        _ = await eventually { model.companion(of: "agent") != nil }
        let altSurvivesOpen = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 2
                && self.altCount(in: root) == 1
        }
        XCTAssertTrue(altSurvivesOpen,
                      "agent pane must stay in the alternate buffer after split open")

        // Close the split: another remount, same invariant.
        model.apply(.splitClose)
        _ = await eventually { model.companion(of: "agent") == nil }
        let altSurvivesClose = await eventually {
            window.contentView.map { self.altCount(in: $0) } == 1
        }
        XCTAssertTrue(altSurvivesClose,
                      "agent pane must stay in the alternate buffer after split close")

        daemon.registry.kill(name: "agent")
    }
}
