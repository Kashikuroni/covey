import XCTest
import CoveyKit

final class CoveyConfigTests: XCTestCase {
    func testMissingFileGivesDefaults() {
        let cfg = CoveyConfig.load(path: "\(NSTemporaryDirectory())nope-\(UInt32.random(in: 0..<UInt32.max)).json")
        XCTAssertEqual(cfg.presets, ["claude", "codex"])
    }

    func testFileRoundTripAndDefaultFirst() throws {
        let path = "\(NSTemporaryDirectory())covey-cfg-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"defaultAgent":"codex","agentPresets":["claude","codex","aider"]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let cfg = CoveyConfig.load(path: path)
        XCTAssertEqual(cfg.presets, ["codex", "claude", "aider"])
    }

    func testDefaultAgentOutsidePresetsIsPrepended() throws {
        let path = "\(NSTemporaryDirectory())covey-cfg-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"defaultAgent":"my-agent"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(CoveyConfig.load(path: path).presets, ["my-agent", "claude", "codex"])
    }
}
