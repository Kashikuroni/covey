import XCTest
@testable import CoveyKit

final class PersistedStateTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        var s = PersistedState(theme: "light", splitPct: 42)
        s.recents = [RecentSession(name: "a", dir: "/w", agent: "claude", resumeCmd: "claude --resume x")]
        s.order = ["a", "b"]
        s.projectNames = ["/w": "Work"]
        s.notes = ["a": "- [ ] task"]
        s.sessions = ["a": PersistedSession(dir: "/w", agent: "claude")]
        s.showSessions = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testNilScalarsAreOmitted() throws {
        let data = try JSONEncoder().encode(PersistedState())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("theme"))      // nil -> omitted
        XCTAssertFalse(json.contains("splitPct"))
        XCTAssertTrue(json.contains("recents"))     // empty array -> present
    }

    func testPushRecentDedupesNewestFirst() {
        var r: [RecentSession] = []
        pushRecent(&r, RecentSession(name: "a", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "b", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "a", dir: "/w2", agent: "sh"))  // re-stop a
        XCTAssertEqual(r.map(\.name), ["a", "b"])   // a moved to front, no dup
        XCTAssertEqual(r.first?.dir, "/w2")          // newest payload wins
    }

    func testPushRecentTruncatesToMax() {
        var r: [RecentSession] = []
        for i in 0..<(maxRecents + 5) {
            pushRecent(&r, RecentSession(name: "s\(i)", dir: "/w", agent: "sh"))
        }
        XCTAssertEqual(r.count, maxRecents)
        XCTAssertEqual(r.first?.name, "s\(maxRecents + 4)")  // last pushed is first
    }
}
