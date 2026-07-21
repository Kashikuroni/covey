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

    private func restoredAgentView(in root: NSView) -> CoveyTerminalView? {
        terminalViews(in: root).first {
            $0.getTerminal().isCurrentBufferAlternate
                && $0.getTerminal().keyboardEnhancementFlags.rawValue == 1
        }
    }

    private func assertShiftEnterIsKittyEncoded(
        by view: CoveyTerminalView,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = TerminalInputProbe()
        view.terminalDelegate = probe
        XCTAssertTrue(window.makeFirstResponder(view), file: file, line: line)
        sendReturnKey(to: view, modifiers: [.shift])
        XCTAssertEqual(
            probe.sent,
            Array("\u{1b}[13;2u".utf8),
            file: file,
            line: line
        )
    }

    func testSplitToggleKeepsAgentAltBufferAndKittyKeyboardState() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/usr", agent: "claude",
            // Overflow the 1 MB ring so the original Kitty push cannot mask a
            // missing synthesized preamble when each fresh view attaches.
            argv: ["/bin/sh", "-c",
                   "printf '\\033[?1049h\\033[>1u\\033[?1003h\\033[?1006h'; "
                   + "/usr/bin/yes x | /usr/bin/head -c 1001000; "
                   + "printf 'READY'; exec cat"],
            name: "agent")
        _ = await eventually { model.sessions.contains { $0.name == "agent" } }
        _ = await eventually {
            daemon.registry.backfill(name: "agent", since: 0)?.gapped == true
        }
        await model.select("agent")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalPaneView(model: model))

        let mounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(mounted, "agent pane should restore alt buffer and Kitty flags")

        model.apply(.splitVertical)
        _ = await eventually { model.companion(of: "agent") != nil }
        let openRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 2
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(openRestored,
                      "agent pane must restore Kitty flags after split open")
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split open")
        }

        model.apply(.splitClose)
        _ = await eventually { model.companion(of: "agent") == nil }
        let closeRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 1
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(closeRestored,
                      "agent pane must restore Kitty flags after split close")
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split close")
        }

        daemon.registry.kill(name: "agent")
    }
}
