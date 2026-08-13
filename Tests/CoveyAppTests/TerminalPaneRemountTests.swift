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

    private func coordinator(
        named name: String,
        in root: NSView
    ) -> TerminalRepresentable.Coordinator? {
        terminalViews(in: root)
            .compactMap {
                $0.terminalDelegate as? TerminalRepresentable.Coordinator
            }
            .first { $0.name == name }
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
        let initialCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(initialCoordinator.lease))

        model.perform(.splitTerminalVertically)
        _ = await eventually { model.companion(of: "agent") != nil }
        let openRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 2
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(openRestored,
                      "agent pane must restore Kitty flags after split open")
        let splitCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertNotEqual(initialCoordinator.lease, splitCoordinator.lease)
        XCTAssertFalse(model.isTerminalViewLeaseCurrent(initialCoordinator.lease))
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(splitCoordinator.lease))
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split open")
        }

        model.perform(.closeTerminalSplit)
        _ = await eventually { model.companion(of: "agent") == nil }
        let closeRestored = await eventually {
            guard let root = window.contentView else { return false }
            return self.terminalViews(in: root).count == 1
                && self.restoredAgentView(in: root) != nil
        }
        XCTAssertTrue(closeRestored,
                      "agent pane must restore Kitty flags after split close")
        let restoredCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent", in: $0)
            }
        )
        XCTAssertNotEqual(splitCoordinator.lease, restoredCoordinator.lease)
        XCTAssertFalse(model.isTerminalViewLeaseCurrent(splitCoordinator.lease))
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(restoredCoordinator.lease))
        if let root = window.contentView,
           let agentView = restoredAgentView(in: root) {
            assertShiftEnterIsKittyEncoded(by: agentView, in: window)
        } else {
            XCTFail("restored agent view missing after split close")
        }

        daemon.registry.kill(name: "agent")
    }

    func testSessionSwitchRotatesAgentResizeLease() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent-a"
        )
        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent-b"
        )
        let loaded = await eventually {
            model.sessions.contains { $0.name == "agent-a" }
                && model.sessions.contains { $0.name == "agent-b" }
        }
        XCTAssertTrue(loaded)

        await model.select("agent-a")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: TerminalPaneView(model: model)
        )

        let firstMounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.coordinator(named: "agent-a", in: root) != nil
        }
        XCTAssertTrue(firstMounted)
        let firstCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent-a", in: $0)
            }
        )
        XCTAssertTrue(model.isTerminalViewLeaseCurrent(firstCoordinator.lease))

        await model.select("agent-b")
        let secondSessionMounted = await eventually {
            guard let root = window.contentView else { return false }
            return self.coordinator(named: "agent-b", in: root) != nil
        }
        XCTAssertTrue(secondSessionMounted)

        await model.select("agent-a")
        let replacementMounted = await eventually {
            guard let root = window.contentView,
                  let coordinator = self.coordinator(
                    named: "agent-a",
                    in: root
                  ) else { return false }
            return coordinator.lease != firstCoordinator.lease
        }
        XCTAssertTrue(replacementMounted)
        let replacementCoordinator = try XCTUnwrap(
            window.contentView.flatMap {
                coordinator(named: "agent-a", in: $0)
            }
        )

        XCTAssertFalse(
            model.isTerminalViewLeaseCurrent(firstCoordinator.lease)
        )
        XCTAssertTrue(
            model.isTerminalViewLeaseCurrent(replacementCoordinator.lease)
        )

        daemon.registry.kill(name: "agent-a")
        daemon.registry.kill(name: "agent-b")
    }

    func testTerminalContentKeepsFourPointInsetsOnPanelEdges() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()

        _ = try daemon.registry.create(
            dir: "/usr",
            agent: "cat",
            argv: ["/bin/cat"],
            name: "agent"
        )
        _ = await eventually {
            model.sessions.contains { $0.name == "agent" }
        }
        await model.select("agent")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSHostingView(rootView: TerminalPaneView(model: model))
        window.contentView = root

        let mounted = await eventually {
            self.terminalViews(in: root).count == 1
        }
        XCTAssertTrue(mounted)
        root.layoutSubtreeIfNeeded()

        let terminal = try XCTUnwrap(terminalViews(in: root).first)
        let frame = terminal.convert(terminal.bounds, to: root)
        let leadingGap = frame.minX - root.bounds.minX
        let trailingGap = root.bounds.maxX - frame.maxX
        let bottomGap = root.isFlipped
            ? root.bounds.maxY - frame.maxY
            : frame.minY - root.bounds.minY
        let topGap = root.isFlipped
            ? frame.minY - root.bounds.minY
            : root.bounds.maxY - frame.maxY

        XCTAssertEqual(leadingGap, 4, accuracy: 0.5)
        XCTAssertEqual(trailingGap, 4, accuracy: 0.5)
        XCTAssertEqual(bottomGap, 4, accuracy: 0.5)
        XCTAssertEqual(topGap, 25, accuracy: 0.5)

        daemon.registry.kill(name: "agent")
    }
}
