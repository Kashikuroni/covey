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
            .disabled(reason: "No terminal split"))
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
}
