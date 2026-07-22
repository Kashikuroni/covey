import XCTest
@testable import CoveydCore
import CoveyKit

final class CodexTraceAdapterTests: XCTestCase {
    private func run(_ jsonl: String) -> [TraceEvent] {
        var adapter = CodexTraceAdapter()
        var seq = 0
        return adapter.consume(lines: jsonl.split(separator: "\n").map { Data($0.utf8) }, seq: &seq)
    }

    func testMetaModelToolCallAndOutput() {
        let jsonl = #"{"type":"session_meta","payload":{"cli_version":"0.144.6"}}"# + "\n" +
                    #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"medium"}}"# + "\n" +
                    #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"ls"}}"# + "\n" +
                    #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"a.txt"}}"# + "\n" +
                    #"{"type":"response_item","payload":{"type":"function_call","name":"read_file","call_id":"c2","arguments":"{}"}}"#
        let events = run(jsonl + "\n")
        let toolCalls = events.filter { if case .toolCall = $0.kind { return true }; return false }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].model, "gpt-5.6-sol")
        XCTAssertEqual(toolCalls[0].effort, "medium")
        XCTAssertEqual(toolCalls[0].cliVersion, "0.144.6")
        guard case .toolCall(let id, let name) = toolCalls[0].kind else { return XCTFail() }
        XCTAssertEqual(id, "c1"); XCTAssertEqual(name, "exec")
        let results = events.filter { if case .toolResult = $0.kind { return true }; return false }
        XCTAssertEqual(results.count, 1)
        guard case .toolResult(let cid, _, _) = results[0].kind else { return XCTFail() }
        XCTAssertEqual(cid, "c1")
    }

    func testTokenCountRateLimitPatchReasoningTurns() {
        let jsonl = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n" +
                    #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"thinking"}]}}"# + "\n" +
                    #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":6,"reasoning_output_tokens":2,"total_tokens":16},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":30.0,"resets_at":1785305140}},"plan_type":"plus"}}"# + "\n" +
                    #"{"type":"event_msg","payload":{"type":"patch_apply_end","changes":{"/a.swift":{"added":3,"removed":1}},"success":true}}"# + "\n" +
                    #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        let events = run(jsonl + "\n")
        XCTAssertTrue(events.contains { if case .turnStarted = $0.kind { return true }; return false })
        XCTAssertTrue(events.contains { if case .turnCompleted = $0.kind { return true }; return false })
        guard let think = events.first(where: { if case .thinking = $0.kind { return true }; return false }),
              case .thinking(let t) = think.kind else { return XCTFail() }
        XCTAssertEqual(t, "thinking")
        guard let tok = events.first(where: { if case .tokenUsage = $0.kind { return true }; return false }),
              case .tokenUsage(let u) = tok.kind else { return XCTFail() }
        XCTAssertEqual(u.input, 10); XCTAssertEqual(u.output, 6)
        XCTAssertEqual(u.cacheRead, 4); XCTAssertEqual(u.reasoning, 2)
        XCTAssertEqual(u.contextWindow, 258400)
        guard let rl = events.first(where: { if case .rateLimit = $0.kind { return true }; return false }),
              case .rateLimit(let pct, _, let plan) = rl.kind else { return XCTFail() }
        XCTAssertEqual(pct, 30.0); XCTAssertEqual(plan, "plus")
        guard let edit = events.first(where: { if case .fileEdit = $0.kind { return true }; return false }),
              case .fileEdit(let path, let added, let removed, _) = edit.kind else { return XCTFail() }
        XCTAssertEqual(path, "/a.swift"); XCTAssertEqual(added, 3); XCTAssertEqual(removed, 1)
    }
}
