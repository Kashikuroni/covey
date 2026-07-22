import XCTest
import CoveyKit

final class TraceEventTests: XCTestCase {
    func testCodableRoundTripPreservesAllFields() throws {
        let event = TraceEvent(
            seq: 7, agent: .main, cli: .codex, cliVersion: "0.144.6",
            model: "gpt-5.6-sol", effort: "medium",
            timestamp: Date(timeIntervalSince1970: 1_753_170_600),
            kind: .toolCall(id: "call_1", name: "exec"),
            raw: #"{"type":"custom_tool_call","name":"exec"}"#)
        let line = try NDJSON.encodeLine(event)
        let decoded = try NDJSON.decoder.decode(TraceEvent.self, from: Data(line))
        XCTAssertEqual(decoded, event)
    }

    func testKindVariantsRoundTrip() throws {
        let kinds: [TraceEvent.Kind] = [
            .turnStarted, .turnCompleted(durationMs: 1200),
            .assistantText(preview: "hi"), .thinking(preview: "hmm"),
            .toolResult(callId: "call_1", isError: true, preview: "boom"),
            .fileEdit(path: "/a.swift", added: 3, removed: 1, diff: "@@"),
            .tokenUsage(TraceEvent.TokenUsage(input: 2, output: 3, cacheRead: 4,
                cacheCreate: 5, reasoning: 6, total: 20, contextWindow: 258_400)),
            .rateLimit(usedPercent: 30, resetsAt: nil, plan: "plus"),
            .webSearch(query: "swift"), .other(label: "compacted"),
        ]
        for kind in kinds {
            let e = TraceEvent(seq: 1, agent: .init(id: "sub1", label: "Task"),
                cli: .claudeCode, timestamp: Date(timeIntervalSince1970: 0),
                kind: kind, raw: "{}")
            let line = try NDJSON.encodeLine(e)
            XCTAssertEqual(try NDJSON.decoder.decode(TraceEvent.self, from: Data(line)), e)
        }
    }
}
