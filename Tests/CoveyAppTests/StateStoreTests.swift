import XCTest
@testable import covey
import CoveyKit

final class StateStoreTests: XCTestCase {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())covey-state-\(UInt32.random(in: 0..<UInt32.max)).json"
    }

    func testSaveFlushLoadRoundTrips() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)
        var s = PersistedState(theme: "light", splitPct: 30)
        s.recents = [RecentSession(name: "a", dir: "/w", agent: "sh")]
        store.save(s)
        store.flush()
        let back = StateStore(path: path).load()
        XCTAssertEqual(back.theme, "light")
        XCTAssertEqual(back.splitPct, 30)
        XCTAssertEqual(back.recents.map(\.name), ["a"])
    }

    func testDebounceCoalescesManySavesIntoOneWrite() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)   // long: nothing fires on its own
        for i in 0..<10 { store.save(PersistedState(splitPct: i)) }
        store.flush()
        XCTAssertEqual(store.writeCount, 1, "10 saves + flush must be a single write")
        XCTAssertEqual(StateStore(path: path).load().splitPct, 9)  // last value won
    }

    func testMissingFileLoadsDefault() {
        let store = StateStore(path: tempPath())   // never written
        XCTAssertEqual(store.load(), PersistedState())
    }

    func testCorruptFileLoadsDefault() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(StateStore(path: path).load(), PersistedState())
    }

    func testNoTempFileLeftBehind() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = StateStore(path: path, debounce: 5)
        store.save(PersistedState(theme: "dark"))
        store.flush()
        // .atomic writes to a sibling temp then renames; nothing but the final file remains.
        let dir = (path as NSString).deletingLastPathComponent
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let base = (path as NSString).lastPathComponent
        XCTAssertFalse(leftovers.contains { $0 != base && $0.contains(base) })
    }
}
