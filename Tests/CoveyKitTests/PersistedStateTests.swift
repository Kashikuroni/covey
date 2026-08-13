import XCTest
@testable import CoveyKit

final class PersistedStateTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        var s = PersistedState(theme: "light", splitPct: 42)
        s.recents = [RecentSession(name: "a", dir: "/w", agent: "claude", resumeCmd: "claude --resume x")]
        s.order = ["a", "b"]
        s.projectNames = ["/w": "Work"]
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

    func testIssueDraftsRoundTrip() throws {
        var st = PersistedState()
        st.issueDrafts = ["/repo": IssueDraft(title: "t", body: "b", assignMe: true)]
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.issueDrafts?["/repo"],
                       IssueDraft(title: "t", body: "b", assignMe: true))
    }

    func testRemovedNoteFieldsAreIgnoredWhenDecodingLegacyState() throws {
        let old = #"{"recents":[],"order":[],"projectOrder":[],"projectNames":{},"projectNotes":{"/repo":"old"},"notes":{"s":"old"},"drafts":{},"sessions":{},"inspectorSplit":true,"inspectorMode":"notes"}"#
        let decoded = try JSONDecoder().decode(PersistedState.self,
                                               from: old.data(using: .utf8)!)
        XCTAssertEqual(decoded.inspectorMode, "notes")

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded)
            as? [String: Any])
        XCTAssertFalse(object.keys.contains("projectNotes"))
        XCTAssertFalse(object.keys.contains("notes"))
        XCTAssertFalse(object.keys.contains("inspectorSplit"))
    }

    func testProviderRoundTrips() throws {
        var s = PersistedState()
        s.provider = "glm"
        s.sessions["s-1"] = PersistedSession(dir: "/tmp", agent: "claude", providerId: "glm")
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back.provider, "glm")
        XCTAssertEqual(back.sessions["s-1"]?.providerId, "glm")
    }

    func testRecentProviderIdRoundTrips() throws {
        var s = PersistedState()
        s.recents = [RecentSession(name: "r", dir: "/tmp", agent: "claude", providerId: "glm")]
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back.recents.first?.providerId, "glm")
    }

    func testLegacyPayloadDecodesWithoutProvider() throws {
        let json = "{\"recents\":[],\"order\":[],\"projectOrder\":[],\"projectNames\":{},\"drafts\":{},\"sessions\":{\"s\":{\"dir\":\"/tmp\",\"agent\":\"claude\"}}}"
        let s = try JSONDecoder().decode(PersistedState.self, from: json.data(using: .utf8)!)
        XCTAssertNil(s.provider)
        XCTAssertNil(s.sessions["s"]?.providerId)
        XCTAssertNil(s.recents.first?.providerId)
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

    func testRecentSessionBranchAndStoppedAtRoundTripAndOldPayloadDecodes() throws {
        let r = RecentSession(name: "a", dir: "/d", agent: "claude",
                              resumeCmd: "claude --resume u", stoppedAt: 1_700_000_000,
                              branch: "feature/search")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentSession.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.branch, "feature/search")
        // Payload written before the optional fields existed still decodes.
        let old = #"{"name":"b","dir":"/d","agent":"sh"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecentSession.self, from: old)
        XCTAssertNil(decoded.stoppedAt)
        XCTAssertNil(decoded.resumeCmd)
        XCTAssertNil(decoded.branch)
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

    func testUsageNotifiedRoundTripAndOmittedWhenNil() throws {
        var st = PersistedState()
        st.usageNotified = ["5h": 1_760_000_000, "7d": 0]
        let back = try JSONDecoder().decode(PersistedState.self,
                                            from: JSONEncoder().encode(st))
        XCTAssertEqual(back.usageNotified, ["5h": 1_760_000_000, "7d": 0])
        // Absent in old files: decodes to nil, encodes to nothing.
        let empty = try JSONDecoder().decode(PersistedState.self,
                                             from: JSONEncoder().encode(PersistedState()))
        XCTAssertNil(empty.usageNotified)
        let json = String(data: try JSONEncoder().encode(PersistedState()), encoding: .utf8)!
        XCTAssertFalse(json.contains("usageNotified"))
    }

    func testUsagePlacementRoundTripAndOmittedWhenNil() throws {
        var state = PersistedState()
        state.usagePlacement = "center"

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: encoded)
        XCTAssertEqual(decoded.usagePlacement, "center")

        let emptyJSON = String(decoding: try JSONEncoder().encode(PersistedState()),
                               as: UTF8.self)
        XCTAssertFalse(emptyJSON.contains("usagePlacement"))
    }

    func testUsageCacheFieldsRoundTrip() throws {
        var st = PersistedState()
        st.claudeUsageEnabled = false
        st.codexUsageEnabled = true
        st.claudeUsage = PersistedUsage(fiveHour: PersistedUsageWindow(utilization: 42, resetUnix: 1),
                                        sevenDay: nil, sevenDaySonnet: nil)
        st.claudePlan = "Max 5×"
        st.codexUsage = PersistedCodexUsage(primaryLabel: "5h",
                                            primary: PersistedUsageWindow(utilization: 8, resetUnix: 1),
                                            secondaryLabel: "7d",
                                            secondary: PersistedUsageWindow(utilization: 22, resetUnix: 2))
        st.codexPlan = "Plus"
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back, st)
    }

    func testUsageCacheFieldsOmittedWhenNilAndOldPayloadDecodes() throws {
        let json = String(decoding: try JSONEncoder().encode(PersistedState()), as: UTF8.self)
        XCTAssertFalse(json.contains("claudeUsageEnabled"))
        XCTAssertFalse(json.contains("codexUsageEnabled"))
        XCTAssertFalse(json.contains("claudeUsage"))
        XCTAssertFalse(json.contains("claudePlan"))
        XCTAssertFalse(json.contains("codexUsage"))
        XCTAssertFalse(json.contains("codexPlan"))
        // A state.json written before these fields existed still decodes.
        let old = #"{"recents":[],"order":[],"projectOrder":[],"projectNames":{},"#
                + #""projectNotes":{},"notes":{},"drafts":{},"sessions":{}}"#
        let decoded = try JSONDecoder().decode(PersistedState.self, from: old.data(using: .utf8)!)
        XCTAssertNil(decoded.claudeUsageEnabled)
        XCTAssertNil(decoded.claudeUsage)
    }
}
