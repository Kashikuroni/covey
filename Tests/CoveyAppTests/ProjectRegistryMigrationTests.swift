import XCTest
import CoveyKit
@testable import covey

/// PersistedState больше не сериализует реестр проектов: демон — источник
/// правды (spec §10). Поля остаются декодируемыми для старых state.json.
final class ProjectRegistryMigrationTests: XCTestCase {
    @MainActor
    func testPmSanitizeDropsProjectFields() throws {
        var state = PersistedState()
        state.projects = ["/old/root"]
        state.projectNames = ["/old/root": "Old"]
        state.projectOrder = ["/old/root"]
        AppModel.pmSanitize(&state)
        XCTAssertNil(state.projects)
        XCTAssertNil(state.projectNames)
        XCTAssertNil(state.projectOrder)
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("/old/root"))
    }

    func testLegacyStateStillDecodes() throws {
        let legacy = """
        {"projects":["/a"],"projectNames":{"/a":"A"},"projectOrder":["/a"],"recents":[],"order":[],"drafts":{},"sessions":{}}
        """
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.projects, ["/a"])
    }
}
