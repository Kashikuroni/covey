import XCTest
import CoveyKit
@testable import CoveydCore

final class ProjectStoreTests: XCTestCase {
    private func makeStore() throws -> ProjectStore {
        let path = "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
        let db = try PMDB(path: path)
        return ProjectStore(db: db)
    }

    func testRegisterDefaultsNameToLastComponent() throws {
        let store = try makeStore()
        let p = try store.register(rootPath: "/dev/bigproj", name: nil, now: 10)
        XCTAssertEqual(p.name, "bigproj")
        XCTAssertEqual(p.rootPath, "/dev/bigproj")
    }

    func testRegisterSameRootIsIdempotent() throws {
        let store = try makeStore()
        let a = try store.register(rootPath: "/dev/x", name: nil, now: 1)
        let b = try store.register(rootPath: "/dev/x", name: nil, now: 2)
        XCTAssertEqual(a.id, b.id)
    }

    /// Review finding 5: повторная регистрация архивированного корня
    /// оживляет проект (removeProject = archive; re-add не должен быть тупиком).
    func testRegisterRevivesArchivedProject() throws {
        let store = try makeStore()
        let p = try store.register(rootPath: "/dev/x", name: nil, now: 1)
        _ = try store.archive(id: p.id, archived: true, expectedRevision: p.revision, now: 2)
        let revived = try store.register(rootPath: "/dev/x", name: nil, now: 3)
        XCTAssertEqual(revived.id, p.id)
        XCTAssertNil(revived.archivedAt)
        XCTAssertEqual(try store.list(includeArchived: false).count, 1)
    }

    func testRenameGuardsRevision() throws {
        let store = try makeStore()
        let p = try store.register(rootPath: "/dev/x", name: nil, now: 1)
        _ = try store.rename(id: p.id, to: "renamed", expectedRevision: p.revision, now: 2)
        XCTAssertThrowsError(try store.rename(id: p.id, to: "again", expectedRevision: p.revision, now: 3)) {
            XCTAssertEqual(($0 as? PMStoreError), .stale)
        }
    }

    func testProjectIDAttributionLongestPrefix() throws {
        let store = try makeStore()
        let big = try store.register(rootPath: "/dev/big", name: nil, now: 1)
        let sub = try store.register(rootPath: "/dev/big/repoA", name: nil, now: 2)
        XCTAssertEqual(store.projectID(forSessionRoot: "/dev/big/repoA"), sub.id)
        XCTAssertEqual(store.projectID(forSessionRoot: "/dev/big/repoB"), big.id)
        XCTAssertNil(store.projectID(forSessionRoot: "/dev/elsewhere"))
    }

    func testMissingFlagWhenRootAbsent() throws {
        let store = try makeStore()
        _ = try store.register(rootPath: "/definitely/not/here-\(UInt32.random(in: 0..<1000))",
                               name: nil, now: 1)
        let list = try store.list(includeArchived: true)
        XCTAssertEqual(list.first?.missing, true)
    }

    func testSeedMigratesStateJSONFields() throws {
        let store = try makeStore()
        var state = PersistedState()
        state.projects = ["/dev/one", "/dev/two"]
        state.projectNames = ["/dev/one": "Первый"]
        state.projectOrder = ["/dev/two", "/dev/one"]
        let seeded = try store.seed(from: state, now: 5)
        XCTAssertEqual(seeded, 2)
        let list = try store.list(includeArchived: false)
        XCTAssertEqual(list.map(\.rootPath).sorted(), ["/dev/one", "/dev/two"])
        XCTAssertEqual(list.first { $0.rootPath == "/dev/one" }?.name, "Первый")
        XCTAssertEqual(list.first { $0.rootPath == "/dev/two" }?.sortOrder, 0) // порядок из projectOrder
        XCTAssertEqual(try store.seed(from: state, now: 6), 0) // повторная миграция — no-op
    }
}
