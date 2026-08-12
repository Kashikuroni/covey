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
}
