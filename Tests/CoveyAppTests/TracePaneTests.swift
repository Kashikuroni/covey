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
}
