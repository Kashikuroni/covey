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

    func testProviderIdRoundTrips() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let metas = [SessionMeta(name: "s1", dir: "/a", agent: "claude",
                                 argv: ["claude"], created: 42, providerId: "glm")]
        RegistryStore(path: path).save(metas)
        XCTAssertEqual(RegistryStore(path: path).load(), metas)
    }

    func testLegacyPayloadDecodesWithoutProviderId() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("[{\"name\":\"s2\",\"dir\":\"/tmp\",\"agent\":\"claude\",\"argv\":[\"claude\"],\"created\":1}]".utf8)
            .write(to: URL(fileURLWithPath: path))
        let loaded = RegistryStore(path: path).load()
        XCTAssertEqual(loaded.first?.name, "s2")
        XCTAssertNil(loaded.first?.providerId)
    }
}
