import XCTest
@testable import covey
import CoveyKit

final class TracePaneTests: XCTestCase {
    func testSummaryLabelsPerKind() {
        func e(_ k: TraceEvent.Kind, model: String? = "gpt-5.6") -> TraceEvent {
            TraceEvent(seq: 0, agent: .main, cli: .codex, model: model,
                       timestamp: Date(), kind: k, raw: "{}")
        }
        XCTAssertEqual(TraceRow.summary(e(.toolCall(id: "1", name: "exec"))), "exec")
        XCTAssertTrue(TraceRow.summary(e(.tokenUsage(.init(input: 1, output: 2, cacheRead: 0,
            cacheCreate: 0, reasoning: 0, total: 3)))).contains("3"))
        XCTAssertEqual(TraceRow.summary(e(.turnStarted)), "turn started")
    }

    func testFormatBytes() {
        XCTAssertEqual(TraceRow.formatBytes(512), "512 B")
        XCTAssertEqual(TraceRow.formatBytes(2048), "2.0 KB")
        XCTAssertEqual(TraceRow.formatBytes(5 * 1024 * 1024), "5.0 MB")
    }

    func testAgentsUniqueMainFirst() {
        let sub = TraceEvent.AgentRef(id: "a", label: "subagent")
        func e(_ agent: TraceEvent.AgentRef) -> TraceEvent {
            TraceEvent(seq: 0, agent: agent, cli: .codex, timestamp: Date(),
                       kind: .turnStarted, raw: "{}")
        }
        let agents = TraceRow.agents([e(sub), e(.main), e(sub)])
        XCTAssertEqual(agents, [.main, sub])
    }

    func testDisplayOrderIsNewestFirst() {
        func e(_ seq: Int) -> TraceEvent {
            TraceEvent(seq: seq, agent: .main, cli: .codex, timestamp: Date(),
                       kind: .turnStarted, raw: "{}")
        }
        XCTAssertEqual(TraceRow.displayOrder([e(0), e(1), e(2)]).map(\.seq), [2, 1, 0])
    }

    func testPrettyJSONFormatsObjectsSortedAndMultiline() {
        let pretty = TraceRow.prettyJSON(#"{"b":2,"a":1}"#)
        XCTAssertTrue(pretty.contains("\n"), "pretty output is multi-line")
        let a = pretty.range(of: "\"a\"")!.lowerBound
        let b = pretty.range(of: "\"b\"")!.lowerBound
        XCTAssertLessThan(a, b, "keys are sorted")
    }

    func testPrettyJSONPassesThroughNonJSON() {
        XCTAssertEqual(TraceRow.prettyJSON("ls -la"), "ls -la")
    }
}
