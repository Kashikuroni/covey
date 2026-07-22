import XCTest
@testable import covey
import CoveyKit

final class TracePaneTests: XCTestCase {
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

    // MARK: - TracePresenter

    private func ev(_ kind: TraceEvent.Kind, raw: String = "{}") -> TraceEvent {
        TraceEvent(seq: 0, agent: .main, cli: .claudeCode, model: "claude-opus-4-8",
                   timestamp: Date(), kind: kind, raw: raw)
    }

    func testKindClassification() {
        XCTAssertEqual(TracePresenter.kind(ev(.toolCall(id: "1", name: "Bash"))), .bash)
        XCTAssertEqual(TracePresenter.kind(ev(.toolCall(id: "1", name: "exec"))), .bash)
        XCTAssertEqual(TracePresenter.kind(ev(.toolCall(id: "1", name: "Read"))), .read)
        XCTAssertEqual(TracePresenter.kind(ev(.toolCall(id: "1", name: "Edit"))), .edit)
        XCTAssertEqual(TracePresenter.kind(ev(.toolCall(id: "1", name: "WebFetch"))), .generic)
        XCTAssertEqual(TracePresenter.kind(ev(.thinking(preview: "x"))), .thinking)
        XCTAssertEqual(TracePresenter.kind(ev(.toolResult(callId: "1", isError: false, preview: "y"))), .result)
        XCTAssertEqual(TracePresenter.kind(ev(.fileEdit(path: "/a", added: 1, removed: 0, diff: nil))), .edit)
        XCTAssertEqual(TracePresenter.kind(ev(.tokenUsage(.init(input: 1, output: 1, cacheRead: 0,
            cacheCreate: 0, reasoning: 0, total: 2)))), .usage)
    }

    func testBashFieldsParsesCommandAndDescription() {
        let raw = #"{"command":"ls -la","description":"list files"}"#
        let f = TracePresenter.bashFields(raw)
        XCTAssertEqual(f.command, "ls -la")
        XCTAssertEqual(f.why, "list files")
        // Codex-style bare string input
        let bare = TracePresenter.bashFields("echo hi")
        XCTAssertEqual(bare.command, "echo hi")
        XCTAssertNil(bare.why)
    }

    func testEditFieldsHandlesEditAndWrite() {
        let edit = TracePresenter.editFields(#"{"file_path":"/a.swift","old_string":"a","new_string":"b"}"#)
        XCTAssertEqual(edit?.path, "/a.swift")
        XCTAssertEqual(edit?.old, "a"); XCTAssertEqual(edit?.new, "b")
        let write = TracePresenter.editFields(#"{"file_path":"/b.swift","content":"hello"}"#)
        XCTAssertEqual(write?.old, ""); XCTAssertEqual(write?.new, "hello")
    }

    func testSplitDiffKeepsContextAndCountsChanges() {
        let old = "a\nb\nc"
        let new = "a\nB\nc"
        let d = TracePresenter.splitDiff(old: old, new: new)
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 1)
        XCTAssertEqual(d.left.map(\.kind), [.context, .del, .context])
        XCTAssertEqual(d.right.map(\.kind), [.context, .add, .context])
        XCTAssertEqual(d.left[1].text, "b"); XCTAssertEqual(d.right[1].text, "B")
    }

    func testGroupedNumberThousands() {
        XCTAssertEqual(TracePresenter.groupedNumber(324308), "324 308")
        XCTAssertEqual(TracePresenter.groupedNumber(2), "2")
        XCTAssertEqual(TracePresenter.groupedNumber(1000), "1 000")
    }

    func testTokenRowsIncludeCoreLines() {
        let rows = TracePresenter.tokenRows(.init(input: 2, output: 280, cacheRead: 324308,
            cacheCreate: 351, reasoning: 0, total: 324941))
        XCTAssertEqual(rows.first?.label, "Новый ввод")
        XCTAssertTrue(rows.contains { $0.label == "Прочитано из кэша" && $0.value == "324 308" })
        XCTAssertTrue(rows.contains { $0.label == "Контекст запроса" })
    }

    func testClockAndStampFormatInFixedZone() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TracePresenter.clock(d, timeZone: utc), "00:00:00")
        XCTAssertEqual(TracePresenter.stamp(d, timeZone: utc), "1970-01-01 00:00:00")
    }

    func testLatestRateLimitPicksMostRecent() {
        func rl(_ seq: Int, _ pct: Double) -> TraceEvent {
            TraceEvent(seq: seq, agent: .main, cli: .codex, timestamp: Date(),
                       kind: .rateLimit(usedPercent: pct, resetsAt: nil, plan: "plus"), raw: "{}")
        }
        let events = [rl(0, 10), ev(.turnStarted), rl(2, 42)]
        XCTAssertEqual(TracePresenter.latestRateLimit(events)?.percent, 42)
        XCTAssertNil(TracePresenter.latestRateLimit([ev(.turnStarted)]))
    }

    func testResetLabelCoarseBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(TracePresenter.resetLabel(now.addingTimeInterval(2 * 86400), now: now), "2 дн")
        XCTAssertEqual(TracePresenter.resetLabel(now.addingTimeInterval(3 * 3600), now: now), "3 ч")
        XCTAssertEqual(TracePresenter.resetLabel(now.addingTimeInterval(120), now: now), "2 мин")
        XCTAssertEqual(TracePresenter.resetLabel(now.addingTimeInterval(-5), now: now), "сейчас")
        XCTAssertNil(TracePresenter.resetLabel(nil, now: now))
    }
}
