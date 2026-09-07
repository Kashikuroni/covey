import XCTest
@testable import covey
@testable import CoveydCore

/// Прогон тестов не должен писать в журнал реального приложения: иначе
/// диагностика по ~/Library/Logs/Covey смешивает события пользователя с
/// фикстурами (ровно на этом однажды сгорела разборка бага с фокусом).
final class LogPathsTests: XCTestCase {
    func testProductionUsesTheUserLogDirectory() {
        XCTAssertEqual(
            LogPaths.resolve(home: "/Users/x", env: [:], testing: false),
            "/Users/x/Library/Logs/Covey")
    }

    func testTestRunGetsAnIsolatedDirectoryOutsideTheUserLogs() {
        let dir = LogPaths.resolve(home: "/Users/x", env: [:], testing: true)
        XCTAssertFalse(dir.hasPrefix("/Users/x/Library/Logs"),
                       "тестовый прогон не трогает пользовательские логи")
        XCTAssertTrue(dir.hasPrefix(NSTemporaryDirectory()), "изоляция во временной папке")
    }

    func testExplicitOverrideWinsInBothModes() {
        let env = [LogPaths.overrideKey: "/tmp/covey-custom"]
        XCTAssertEqual(LogPaths.resolve(home: "/Users/x", env: env, testing: false),
                       "/tmp/covey-custom")
        XCTAssertEqual(LogPaths.resolve(home: "/Users/x", env: env, testing: true),
                       "/tmp/covey-custom")
    }

    func testEmptyOverrideIsIgnored() {
        XCTAssertEqual(
            LogPaths.resolve(home: "/Users/x", env: [LogPaths.overrideKey: ""],
                             testing: false),
            "/Users/x/Library/Logs/Covey")
    }

    /// Живая проверка: в этом самом процессе логи уехали из прод-каталога.
    func testThisProcessIsDetectedAsATestRun() {
        XCTAssertTrue(LogPaths.isTesting)
        XCTAssertFalse(LogPaths.directory.hasPrefix(NSHomeDirectory() + "/Library/Logs"))
        for path in [PaneLayoutLog.path, UsageLog.path] {
            XCTAssertTrue(path.hasPrefix(LogPaths.directory),
                          "\(path) должен лежать в тестовом каталоге")
        }
    }
}
