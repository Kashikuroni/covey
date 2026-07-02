import XCTest
@testable import CoveydCore

final class RegistryStoreTests: XCTestCase {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())covey-registry-\(UInt32.random(in: 0..<UInt32.max)).json"
    }

    func testRoundTrip() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let metas = [SessionMeta(name: "s1", dir: "/a", agent: "claude",
                                 argv: ["claude"], created: 42)]
        RegistryStore(path: path).save(metas)
        XCTAssertEqual(RegistryStore(path: path).load(), metas)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(RegistryStore(path: tempPath()).load(), [])
    }

    func testCorruptFileLoadsEmpty() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(RegistryStore(path: path).load(), [])
    }
}
