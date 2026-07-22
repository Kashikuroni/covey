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
}
