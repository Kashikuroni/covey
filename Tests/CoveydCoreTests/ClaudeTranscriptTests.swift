import XCTest
@testable import CoveydCore

final class ClaudeTranscriptTests: XCTestCase {
    private let fable = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":"claude-fable-5"}}"#
    private let opus = #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8"}}"#
    private let side = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","model":"claude-haiku-4-5-20251001"}}"#
    private let synthetic = #"{"type":"assistant","message":{"role":"assistant","model":"<synthetic>"}}"#
    private let user = #"{"type":"user","message":{"role":"user"}}"#

    private func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    func testProjectSlugReplacesEveryNonAlphanumeric() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(cwd: "/Users/kashikuroni/projects/pets/covey"),
            "-Users-kashikuroni-projects-pets-covey")
        // A dot after the slash yields a double dash — real example from
        // ~/.claude/projects: /Users/x/.claude/jobs -> -Users-x--claude-jobs.
        XCTAssertEqual(ClaudeTranscript.projectSlug(cwd: "/Users/x/.claude/jobs"),
                       "-Users-x--claude-jobs")
        XCTAssertEqual(ClaudeTranscript.projectSlug(cwd: "/w/my_app.v2"), "-w-my-app-v2")
        // Case is preserved (real slug: ...bug-374-OOM-wb-unit).
        XCTAssertEqual(ClaudeTranscript.projectSlug(cwd: "/w/OOM"), "-w-OOM")
    }

    func testSessionUUIDParsesResumeCmd() {
        XCTAssertEqual(
            ClaudeTranscript.sessionUUID(
                resumeCmd: "claude --resume 0B154175-0F2E-43E8-B5B0-97EC3CB0E6A4"),
            "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4")
        XCTAssertNil(ClaudeTranscript.sessionUUID(resumeCmd: nil))
        XCTAssertNil(ClaudeTranscript.sessionUUID(resumeCmd: "claude --resume"))
        XCTAssertNil(ClaudeTranscript.sessionUUID(resumeCmd: "claude --resume not-a-uuid"))
        XCTAssertNil(ClaudeTranscript.sessionUUID(resumeCmd: "/bin/zsh -l"))
    }

    func testPathJoinsRootSlugAndUUID() {
        XCTAssertEqual(
            ClaudeTranscript.path(projectsRoot: "/root", cwd: "/w/app", uuid: "u-1"),
            "/root/-w-app/u-1.jsonl")
    }

    func testLastAssistantModelPicksLastMainLoopEntry() {
        XCTAssertEqual(ClaudeTranscript.lastAssistantModel(tail: tail([user, fable, user, opus])),
                       "claude-opus-4-8")
    }

    func testLastAssistantModelSkipsSidechainAndSynthetic() {
        XCTAssertEqual(ClaudeTranscript.lastAssistantModel(tail: tail([fable, side, synthetic])),
                       "claude-fable-5")
    }

    func testLastAssistantModelNilWhenNoAssistantLines() {
        XCTAssertNil(ClaudeTranscript.lastAssistantModel(tail: tail([user, user])))
        XCTAssertNil(ClaudeTranscript.lastAssistantModel(tail: Data()))
    }

    func testLastAssistantModelSurvivesTruncatedFirstLine() {
        // A 64K tail almost always starts mid-line; the parser must skip it.
        let truncated = String(fable.dropFirst(20))
        XCTAssertEqual(ClaudeTranscript.lastAssistantModel(tail: tail([truncated, opus])),
                       "claude-opus-4-8")
    }

    func testReadTailReturnsLastBytes() throws {
        let path = "\(NSTemporaryDirectory())covey-tail-\(UInt32.random(in: 0..<UInt32.max)).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (String(repeating: "x", count: 100) + "TAIL")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let data = ClaudeTranscript.readTail(path: path, maxBytes: 4)
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "TAIL")
        XCTAssertNil(ClaudeTranscript.readTail(path: path + ".missing"))
    }
}
