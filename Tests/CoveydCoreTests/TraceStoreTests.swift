import XCTest
@testable import CoveydCore
import CoveyKit

final class TraceStoreTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = "\(NSTemporaryDirectory())covey-trace-\(UUID().uuidString)"
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func ev(_ seq: Int) -> TraceEvent {
        TraceEvent(seq: seq, agent: .main, cli: .codex,
                   timestamp: Date(timeIntervalSince1970: 100), kind: .turnStarted, raw: "{}")
    }

    func testAppendReadSinceAndLastSeq() {
        let store = TraceStore(root: root)
        store.append(sessionKey: "s1", events: [ev(0), ev(1), ev(2)])
        store.append(sessionKey: "s1", events: [ev(3)])
        XCTAssertEqual(store.read(sessionKey: "s1", sinceSeq: 0).map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(store.read(sessionKey: "s1", sinceSeq: 2).map(\.seq), [2, 3])
        XCTAssertEqual(store.lastSeq(sessionKey: "s1"), 3)
        XCTAssertEqual(store.lastSeq(sessionKey: "missing"), -1)
    }

    func testPersistsAcrossInstances() {
        TraceStore(root: root).append(sessionKey: "s1", events: [ev(0), ev(1)])
        XCTAssertEqual(TraceStore(root: root).read(sessionKey: "s1", sinceSeq: 0).count, 2)
    }
}
