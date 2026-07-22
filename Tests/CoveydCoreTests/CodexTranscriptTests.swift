import XCTest
@testable import CoveydCore

final class CodexTranscriptTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = "\(NSTemporaryDirectory())covey-codex-transcript-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testConfiguredModelReadsOnlyRootAssignment() throws {
        let path = "\(root)/config.toml"
        try """
        # model = "commented"
        model = "gpt-5.6-terra" # active default
        [profiles.fast]
        model = "gpt-5.5-mini"
        """.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(CodexTranscript.configuredModel(path: path), "gpt-5.6-terra")
        XCTAssertNil(CodexTranscript.configuredModel(path: "\(root)/missing.toml"))
    }

    func testCommandModelAndCodexClassification() {
        XCTAssertEqual(CodexTranscript.commandModel("codex -m gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(CodexTranscript.commandModel("/opt/bin/codex --model=gpt-5.6-terra"),
                       "gpt-5.6-terra")
        XCTAssertEqual(CodexTranscript.commandModel("codex --model gpt-5.4"), "gpt-5.4")
        XCTAssertNil(CodexTranscript.commandModel("codex --search"))
        XCTAssertTrue(CodexTranscript.isCodexAgent("/opt/bin/codex --search"))
        XCTAssertFalse(CodexTranscript.isCodexAgent("claude"))
    }

    func testMetadataAndLatestTurnModelIgnoreMalformedLines() {
        let jsonl = """
        not-json
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/work/app","timestamp":"2026-07-22T08:30:00.250Z"}}
        {"type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}

        """
        let data = Data(jsonl.utf8)
        let metadata = CodexTranscript.metadata(head: data)
        XCTAssertEqual(metadata?.id, "thread-1")
        XCTAssertEqual(metadata?.cwd, "/work/app")
        XCTAssertNotNil(metadata?.timestamp)
        XCTAssertEqual(CodexTranscript.lastTurnModel(tail: data), "gpt-5.6-terra")
        XCTAssertNil(CodexTranscript.lastTurnModel(tail: Data("partial\n{}\n".utf8)))
    }

    func testRolloutPathsInspectCreationDayAndAdjacentDaysOnly() throws {
        let sessions = "\(root)/sessions"
        for day in ["2026/07/21", "2026/07/22", "2026/07/23", "2026/07/24"] {
            try FileManager.default.createDirectory(atPath: "\(sessions)/\(day)",
                                                    withIntermediateDirectories: true)
            let filenameDay = day.replacingOccurrences(of: "/", with: "-")
            try "{}\n".write(toFile: "\(sessions)/\(day)/rollout-\(filenameDay).jsonl",
                              atomically: true, encoding: .utf8)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let created = Int64(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 22))!.timeIntervalSince1970)

        let paths = CodexTranscript.rolloutPaths(sessionsRoot: sessions, created: created)
        XCTAssertEqual(paths.count, 3)
        XCTAssertFalse(paths.contains { $0.contains("2026/07/24") })
    }
}
