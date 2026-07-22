import XCTest
@testable import CoveydCore
import CoveyKit

final class ClaudeTraceAdapterTests: XCTestCase {
    private func run(_ jsonl: String) -> [TraceEvent] {
        var adapter = ClaudeTraceAdapter()
        var seq = 0
        let lines = jsonl.split(separator: "\n").map { Data($0.utf8) }
        return adapter.consume(lines: lines, seq: &seq)
    }

    func testAssistantTextToolUseAndUsage() {
        let line = #"{"type":"assistant","version":"2.0.1","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Working"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":2,"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}"#
        let events = run(line + "\n")
        XCTAssertEqual(events.map(\.seq), [0, 1, 2])
        XCTAssertEqual(events.map(\.model), ["claude-opus-4-8", "claude-opus-4-8", "claude-opus-4-8"])
        XCTAssertEqual(events[0].cli, .claudeCode)
        XCTAssertEqual(events[0].cliVersion, "2.0.1")
        guard case .assistantText(let p) = events[0].kind else { return XCTFail() }
        XCTAssertEqual(p, "Working")
        guard case .toolCall(let id, let name) = events[1].kind else { return XCTFail() }
        XCTAssertEqual(id, "toolu_1"); XCTAssertEqual(name, "Bash")
        XCTAssertEqual(events[1].raw, #"{"command":"ls"}"#)
        guard case .tokenUsage(let u) = events[2].kind else { return XCTFail() }
        XCTAssertEqual(u.input, 2); XCTAssertEqual(u.output, 10)
        XCTAssertEqual(u.cacheRead, 100); XCTAssertEqual(u.cacheCreate, 5)
    }

    func testMalformedLineSkipped() {
        XCTAssertEqual(run("not-json\n{}\n").count, 0)
    }
}
