import XCTest
@testable import covey

final class CommandSearchTests: XCTestCase {
    private func ids(_ query: String) -> [AppCommand] {
        CommandSearch.groups(query: query).flatMap(\.matches).map { $0.descriptor.id }
    }

    func testEmptyQueryKeepsFixedCatalogOrder() {
        XCTAssertEqual(ids(""), CommandCatalog.all.map(\.id))
    }

    func testEnglishRussianAndWrongLayoutFindSplit() {
        XCTAssertEqual(ids("split").first, .splitTerminalVertically)
        XCTAssertEqual(ids("вертикальный сплит").first, .splitTerminalVertically)
        XCTAssertTrue(ids("ыздше").contains(.splitTerminalVertically))
    }

    func testRussianCategoryFindsEverySessionCommand() {
        let found = Set(ids("сессия"))
        let expected: Set<AppCommand> = [
            .newSession, .newSessionInCurrentProject, .recentSessions, .filterSessions,
            .killSession, .renameSession, .restartSession, .restartAllClaudeSessions,
            .moveSessionUp, .moveSessionDown,
        ]
        XCTAssertEqual(found, expected)
    }

    func testGroupsRankByTheirBestCommand() {
        let groups = CommandSearch.groups(query: "split")
        XCTAssertEqual(groups.first?.category, .terminal)
        XCTAssertEqual(groups.first?.matches.first?.descriptor.id, .splitTerminalVertically)
    }

    func testExactTitleRanksAboveAlias() {
        XCTAssertEqual(ids("Settings").first, .settings)
    }

    func testUnknownQueryReturnsNoGroups() {
        XCTAssertTrue(CommandSearch.groups(query: "zzqxjv").isEmpty)
    }
}
