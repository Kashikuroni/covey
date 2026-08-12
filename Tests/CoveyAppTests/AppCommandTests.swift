import XCTest
@testable import covey

final class AppCommandTests: XCTestCase {
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

        model.setFocus(.sessions)
        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.focus])

        daemon.registry.kill(name: "agent")
    }

    func testImplementedLeaderLeavesRouteThroughSemanticCommands() {
        let leaves: [(LeaderMenu, Character, AppCommand)] = [
            (.root, "l", .showLimitsDetail),
            (.git, "i", .createGitHubIssue), (.git, "l", .openIssueList),
            (.git, "p", .promoteWorktree), (.git, "b", .deleteSessionBranch),
            (.git, "c", .cleanupMergedBranches), (.git, "r", .returnToRepositoryRoot),
            (.session, "r", .renameSession), (.session, "R", .renameProject),
            (.session, "u", .restartSession), (.session, "U", .restartAllClaudeSessions),
            (.terminal, "v", .splitTerminalVertically),
            (.terminal, "h", .splitTerminalHorizontally),
            (.terminal, "x", .closeTerminalSplit),
            (.ui, "s", .toggleSessionsPanel), (.ui, "i", .toggleInspector),
            (.ui, "a", .toggleAgentTrace), (.ui, "f", .toggleStatusBar),
            (.ui, "h", .toggleTopBar), (.ui, "t", .toggleTheme),
            (.ui, "l", .cycleUsagePlacement),
            (.project, "a", .addProject), (.project, "d", .removeProject),
        ]

        for (menu, key, command) in leaves {
            let context = KeyRouter.Context(mode: .leader(menu), focus: .sessions,
                                            vimMode: true, sheetOpen: false)
            XCTAssertEqual(KeyRouter.route(KeyInput(char: key), context: context),
                           .command(command), "\(menu) \(key)")
        }
    }
}
