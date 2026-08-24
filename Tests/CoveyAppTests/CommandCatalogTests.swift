import Foundation
import SwiftUI
import XCTest
@testable import covey

final class CommandCatalogTests: XCTestCase {
    func testCatalogCoversEveryCommandExactlyOnce() {
        XCTAssertEqual(Set(CommandCatalog.all.map(\.id)), Set(AppCommand.allCases))
        XCTAssertEqual(CommandCatalog.all.count, AppCommand.allCases.count)
    }

    func testCategoryOrderIsStable() {
        XCTAssertEqual(CommandCategory.allCases,
                       [.session, .git, .terminal, .view, .project, .app])
    }

    func testEveryCommandHasRussianDiscoveryText() throws {
        let cyrillic = try NSRegularExpression(pattern: "[А-Яа-яЁё]")
        for command in CommandCatalog.all {
            let text = command.aliases.joined(separator: " ")
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNotNil(cyrillic.firstMatch(in: text, range: range), command.title)
        }
    }

    func testDirectShortcutsAreUnique() {
        let keys = CommandCatalog.all.compactMap(\.shortcut).map {
            "\($0.modifiers.rawValue):\($0.key)"
        }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testIssueSixTerminalAndLimitsShortcuts() throws {
        let expected: [(AppCommand, Character, EventModifiers, String)] = [
            (.splitTerminalVertically, "d", .command, "⌘D"),
            (.splitTerminalHorizontally, "d", [.command, .shift], "⌘⇧D"),
            (.closeTerminalSplit, "w", .command, "⌘W"),
            (.showLimitsDetail, "l", .command, "⌘L"),
        ]

        for (command, key, modifiers, display) in expected {
            let shortcut = try XCTUnwrap(CommandCatalog.descriptor(for: command).shortcut)
            XCTAssertEqual(shortcut.key, key, "\(command)")
            XCTAssertEqual(shortcut.modifiers, modifiers, "\(command)")
            XCTAssertEqual(shortcut.display, display, "\(command)")
        }

        XCTAssertNil(CommandCatalog.descriptor(for: .killSession).shortcut)
    }

    func testFormerLeaderCommandsRemainInCatalog() {
        let expected: Set<AppCommand> = [
            .showLimitsDetail, .createGitHubIssue, .openIssueList, .promoteWorktree,
            .deleteSessionBranch, .cleanupMergedBranches, .returnToRepositoryRoot,
            .renameSession, .renameProject, .restartSession, .restartAllClaudeSessions,
            .splitTerminalVertically, .splitTerminalHorizontally, .closeTerminalSplit,
            .toggleSessionsPanel, .toggleInspector, .toggleAgentTrace, .toggleStatusBar,
            .toggleTopBar, .toggleTheme, .cycleUsagePlacement, .addProject, .removeProject,
        ]

        XCTAssertTrue(expected.isSubset(of: Set(CommandCatalog.all.map(\.id))))
    }
}
