import AppKit
import XCTest
@testable import covey

final class AppCommandTests: XCTestCase {
    func testCommandWIsReservedAndOnlyClosesSplitFromTerminal() {
        XCTAssertEqual(commandWHandling(focus: .terminal, inputMode: .normal),
                       .perform(.closeTerminalSplit))
        XCTAssertEqual(commandWHandling(focus: .sessions, inputMode: .normal),
                       .consume)
        XCTAssertEqual(commandWHandling(focus: .inspector, inputMode: .normal),
                       .consume)
        XCTAssertEqual(commandWHandling(focus: .terminal, inputMode: .limits),
                       .consume)
        XCTAssertEqual(commandWHandling(focus: .terminal,
                                        inputMode: .normal,
                                        modalPresented: true),
                       .consume)
    }

    func testCommandWDetectionUsesPhysicalKeyAcrossLayoutsAndCapsLock() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "ц",
            charactersIgnoringModifiers: "ц",
            isARepeat: false,
            keyCode: 13
        ))

        XCTAssertTrue(isCommandW(event))
    }

    func testCommandWDetectionRejectsOtherModifiedWShortcuts() throws {
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift],
                                                  [.command, .option],
                                                  [.command, .control],
                                                  [.command, .function]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            ))

            XCTAssertFalse(isCommandW(event), "\(modifiers)")
        }
    }

    func testPaletteDoesNotRestoreResponderOverLimitsOverlay() {
        XCTAssertTrue(shouldRestoreCommandPaletteResponder(inputMode: .normal))
        XCTAssertTrue(shouldRestoreCommandPaletteResponder(inputMode: .help))
        XCTAssertFalse(shouldRestoreCommandPaletteResponder(inputMode: .limits))
    }

    @MainActor
    func testPaletteToggleResetsTransientOverlayButModalBlocksOpening() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)

        model.apply(.command(.showKeyboardHelp))
        model.openCommandPalette()

        XCTAssertTrue(model.commandPalettePresented)
        XCTAssertEqual(model.inputMode, .normal)

        model.toggleCommandPalette()
        XCTAssertFalse(model.commandPalettePresented)

        model.modal = .settings
        model.openCommandPalette()
        XCTAssertFalse(model.commandPalettePresented)
    }

    @MainActor
    func testDisabledCommandDoesNotDismissOrExecute() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)

        model.openCommandPalette()
        model.perform(.killSession)

        XCTAssertTrue(model.commandPalettePresented)
        XCTAssertNil(model.modal)
    }

    @MainActor
    func testEnabledCommandDismissesBeforePresentingItsSheet() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)

        model.openCommandPalette()
        model.perform(.newSession)

        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertEqual(model.modal, .newSession)
    }

    @MainActor
    func testClosingPaletteRefocusesTerminalOnlyForTerminalZone() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/tmp",
            agent: "claude",
            argv: ["/bin/cat"],
            name: "agent"
        )
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        model.focusPane("agent")

        var commands: [AppModel.TerminalCommand] = []
        model.setTerminalCommandHandler(for: "agent") { commands.append($0) }

        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.focus])

        model.openCommandPalette()
        model.perform(.showKeyboardHelp)
        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.focus, .focus],
                       "Help keeps the terminal as its responder after the palette closes")
        model.apply(.closeOverlay)

        model.setFocus(.sessions)
        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.focus, .focus])

        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testLimitsOverlayTemporarilyOwnsTerminalFocus() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(
            dir: "/tmp",
            agent: "claude",
            argv: ["/bin/cat"],
            name: "agent"
        )
        _ = await eventually { model.sessions.count == 1 }
        await model.select("agent")
        model.focusPane("agent")

        var commands: [AppModel.TerminalCommand] = []
        model.setTerminalCommandHandler(for: "agent") { commands.append($0) }

        model.perform(.showLimitsDetail)
        XCTAssertEqual(model.inputMode, .limits)
        XCTAssertEqual(commands, [.blur])

        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.blur],
                       "closing the palette must not steal focus from limits")

        model.apply(.closeOverlay)
        XCTAssertEqual(model.inputMode, .normal)
        XCTAssertEqual(commands, [.blur, .focus])

        daemon.registry.kill(name: "agent")
    }

}
