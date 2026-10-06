import XCTest
@testable import covey

final class CommandAvailabilityTests: XCTestCase {
    func testAlwaysAvailableCommands() {
        for command in [AppCommand.newSession, .recentSessions, .toggleTheme,
                        .focusSessionList, .addProject, .settings] {
            XCTAssertEqual(CommandRules.availability(for: command, context: .init()), .enabled)
        }
    }

    func testSessionAndSplitReasons() {
        XCTAssertEqual(CommandRules.availability(for: .killSession, context: .init()),
                       .disabled(reason: "No session selected"))
        XCTAssertEqual(CommandRules.availability(
            for: .closeTerminalSplit,
            context: .init(hasSelectedSession: true)),
                       .disabled(reason: "Nothing to close"))
    }

    func testSessionCyclingRequiresVisibleSessions() {
        for command in [AppCommand.selectPreviousSession, .selectNextSession] {
            XCTAssertEqual(CommandRules.availability(for: command, context: .init()),
                           .disabled(reason: "No visible sessions"))
            XCTAssertEqual(CommandRules.availability(
                for: command,
                context: .init(visibleSessionCount: 1)),
                           .enabled)
        }
    }

    func testCloseSplitRequiresTerminalFocus() {
        var context = CommandContext(hasSelectedSession: true,
                                     hasTerminalSplit: true,
                                     canCloseFocusedPane: true)

        XCTAssertEqual(CommandRules.availability(for: .closeTerminalSplit,
                                                 context: context),
                       .disabled(reason: "Terminal is not focused"))

        context.terminalFocused = true
        XCTAssertEqual(CommandRules.availability(for: .closeTerminalSplit,
                                                 context: context),
                       .enabled)
        XCTAssertEqual(CommandRules.availability(for: .focusTerminalSplit,
                                                 context: context),
                       .enabled)
    }

    func testGitReasonsProgressWithContext() {
        XCTAssertEqual(CommandRules.availability(
            for: .deleteSessionBranch,
            context: .init(hasSelectedSession: true,
                           selectedHasGit: true,
                           selectedBranch: "main",
                           selectedBranchProtected: true)),
            .disabled(reason: "Branch is protected"))
        XCTAssertEqual(CommandRules.availability(
            for: .deleteSessionBranch,
            context: .init(hasSelectedSession: true,
                           selectedHasGit: true,
                           selectedBranch: "feature")),
            .enabled)
    }

    func testInspectorAndProjectReasons() {
        XCTAssertEqual(CommandRules.availability(for: .focusIssues, context: .init()),
                       .disabled(reason: "Inspector is hidden"))
        XCTAssertEqual(CommandRules.availability(for: .renameProject, context: .init()),
                       .disabled(reason: "No project selected"))
    }

    func testEveryCommandHasAnAvailabilityRule() {
        let results = AppCommand.allCases.map {
            CommandRules.availability(for: $0, context: .init())
        }
        XCTAssertEqual(results.count, AppCommand.allCases.count)
    }

    func testToggleReviewNeedsASessionOrALiveReview() {
        XCTAssertEqual(CommandRules.availability(for: .toggleReview, context: .init()),
                       .disabled(reason: "No session selected"))
        // No git check here: a session outside git gets a toast instead.
        XCTAssertEqual(CommandRules.availability(for: .toggleReview,
                                                 context: .init(hasSelectedSession: true)), .enabled)
        XCTAssertEqual(CommandRules.availability(for: .toggleReview,
                                                 context: .init(hasActiveReview: true)), .enabled)
        let descriptor = CommandCatalog.descriptor(for: .toggleReview)
        XCTAssertEqual(descriptor.title, "Review")
        XCTAssertEqual(descriptor.shortcut?.display, "⌥⌘R")
    }

    func testReviewModeDisablesSessionCommandsWithAReason() {
        let context = CommandContext(hasSelectedSession: true, hasProject: true, selectedHasGit: true,
                                     hasTerminalSplit: true, inspectorShown: true,
                                     visibleSessionCount: 9, terminalFocused: true,
                                     canCloseFocusedPane: true, reviewOpen: true, hasActiveReview: true)
        let blocked: [AppCommand] = [
            .selectSession1, .selectSession9, .selectPreviousSession, .selectNextSession,
            .killSession, .renameSession, .newSession, .splitTerminalVertically,
            .splitTerminalHorizontally, .closeTerminalSplit, .focusSessionList, .focusAgent,
            .focusIssues, .focusTerminalSplit, .focusTrace, .toggleInspector, .toggleSessionsPanel,
            .toggleTopBar, .toggleStatusBar, .showKeyboardHelp,
            // Adding a project selects it: the session behind Review would
            // be deselected and its pane unmounted.
            .addProject,
        ]
        for command in blocked {
            XCTAssertEqual(CommandRules.availability(for: command, context: context),
                           .disabled(reason: "Review is open"), "\(command)")
        }
    }

    func testReviewModeKeepsTheToggleAndAppCommands() {
        let context = CommandContext(reviewOpen: true)
        XCTAssertEqual(CommandRules.availableInReview, [
            .toggleReview, .toggleTheme, .showProviders,
            .showLimitsDetail, .settings, .searchLogs,
        ])
        for command in CommandRules.availableInReview {
            XCTAssertEqual(CommandRules.availability(for: command, context: context), .enabled, "\(command)")
        }
    }
}
