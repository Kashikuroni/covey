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

    func testSplitAxesRoundTrip() throws {
        var st = PersistedState()
        st.splitAxes = ["agent": "h"]
        let data = try JSONEncoder().encode(st)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(back.splitAxes, ["agent": "h"])
    }

    func testIssueDraftsAndInspectorSplitRoundTrip() throws {
        var st = PersistedState()
        st.issueDrafts = ["/repo": IssueDraft(title: "t", body: "b", assignMe: true)]
        st.inspectorSplit = true
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.issueDrafts?["/repo"],
                       IssueDraft(title: "t", body: "b", assignMe: true))
        XCTAssertEqual(back.inspectorSplit, true)
    }

    func testPushRecentDedupesNewestFirst() {
        var r: [RecentSession] = []
        pushRecent(&r, RecentSession(name: "a", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "b", dir: "/w", agent: "sh"))
        pushRecent(&r, RecentSession(name: "a", dir: "/w2", agent: "sh"))  // re-stop a
        XCTAssertEqual(r.map(\.name), ["a", "b"])   // a moved to front, no dup
        XCTAssertEqual(r.first?.dir, "/w2")          // newest payload wins
    }

    func testHumanizeAge() {
        XCTAssertEqual(humanizeAge(0), "0s")
        XCTAssertEqual(humanizeAge(59), "59s")
        XCTAssertEqual(humanizeAge(60), "1m")
        XCTAssertEqual(humanizeAge(3599), "59m")
        XCTAssertEqual(humanizeAge(3600), "1h")
        XCTAssertEqual(humanizeAge(86_399), "23h")
        XCTAssertEqual(humanizeAge(86_400), "1d")
        XCTAssertEqual(humanizeAge(-5), "0s", "clock skew clamps to zero")
    }

    func testRecentSessionStoppedAtRoundTripsAndOldPayloadDecodes() throws {
        let r = RecentSession(name: "a", dir: "/d", agent: "claude",
                              resumeCmd: "claude --resume u", stoppedAt: 1_700_000_000)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentSession.self, from: data)
        XCTAssertEqual(back, r)
        // Payload written before the field existed decodes with stoppedAt nil.
        let old = #"{"name":"b","dir":"/d","agent":"sh"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecentSession.self, from: old)
        XCTAssertNil(decoded.stoppedAt)
        XCTAssertNil(decoded.resumeCmd)
    }

    func testPushRecentTruncatesToMax() {
        var r: [RecentSession] = []
        for i in 0..<(maxRecents + 5) {
            pushRecent(&r, RecentSession(name: "s\(i)", dir: "/w", agent: "sh"))
        }
        XCTAssertEqual(r.count, maxRecents)
        XCTAssertEqual(r.first?.name, "s\(maxRecents + 4)")  // last pushed is first
    }

    func testProjectsRoundTripAndOmittedWhenNil() throws {
        var st = PersistedState()
        st.projects = ["/repo/x", "/repo/y"]
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.projects, ["/repo/x", "/repo/y"])
        // Absent in old files: decodes to nil, encodes to nothing.
        let empty = try JSONDecoder().decode(PersistedState.self,
                                             from: JSONEncoder().encode(PersistedState()))
        XCTAssertNil(empty.projects)
    }
}
