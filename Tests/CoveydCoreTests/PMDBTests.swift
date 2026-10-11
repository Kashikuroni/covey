import XCTest
@testable import CoveydCore

final class PMDBTests: XCTestCase {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())covey-pm-\(UInt32.random(in: 0..<UInt32.max)).db"
    }

    func testSchemaCreatedAndVersionSet() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try PMDB(path: path)
        defer { db.close() }
        XCTAssertEqual(db.schemaVersion, 1)
        try db.run("INSERT INTO projects (id, root_path, name, sort_order, created_at) VALUES (?,?,?,?,?)",
                   [.text("p1"), .text("/a/b"), .text("b"), .int(0), .int(1)])
        let rows = try db.query("SELECT id, name FROM projects", []) { $0.string(0) }
        XCTAssertEqual(rows, ["p1"])
    }

    func testReopenKeepsDataAndSkipsMigration() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try PMDB(path: path)
        try first.run("INSERT INTO projects (id, root_path, name, sort_order, created_at) VALUES (?,?,?,?,?)",
                      [.text("p1"), .text("/a/b"), .text("b"), .int(0), .int(1)])
        first.close()
        let second = try PMDB(path: path)
        defer { second.close() }
        XCTAssertEqual(try second.query("SELECT COUNT(*) c FROM projects", []) { $0.int(0) }.first, 1)
        // Миграция не создаёт бэкап на уже актуальной схеме.
        XCTAssertNil(PMDB.latestBackup(nextTo: path))
    }

    func testCorruptDatabaseRecoversFresh() throws {
        let path = tempPath()
        try Data("definitely not sqlite".utf8).write(to: URL(fileURLWithPath: path))
        let db = try PMDB(path: path)   // не бросает — восстанавливается
        defer { db.close() }
        XCTAssertEqual(db.schemaVersion, 1)
        XCTAssertEqual(try db.query("SELECT COUNT(*) c FROM projects", []) { $0.int(0) }.first, 0)
        // Битый файл сохранён рядом как .corrupt-<ts>
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let corrupts = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix(base + ".corrupt-") }
        XCTAssertFalse(corrupts.isEmpty)
    }
}
