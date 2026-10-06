import XCTest
@testable import CoveydCore
import CoveyKit

/// CodexUsageScanner: чистый парсер rollout-строк в TokenEvent-ы прогноза.
/// Правила нормализации — спека «Codex GPT Analytics», таблица раздела
/// «Разбор Codex rollout»: uncached input = input − cached, cached — cache
/// read, reasoning не прибавляется к total повторно.
final class CodexUsageScannerTests: XCTestCase {
    private let key = "codex:s1"

    private func turnContext(_ model: String) -> Data {
        Data(#"{"type":"turn_context","payload":{"model":"\#(model)","effort":"medium"}}"#.utf8)
    }

    private func tokenCount(input: Double, cached: Double, output: Double,
                            reasoning: Double = 0, total: Double? = nil,
                            timestamp: String? = "2026-10-06T10:00:00.125Z") -> Data {
        var usage = #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total ?? input + output)}"#
        if let total { usage = #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)}"# }
        let info = #"{"last_token_usage":\#(usage),"model_context_window":258400}"#
        let ts = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        return Data(#"{\#(ts)"type":"event_msg","payload":{"type":"token_count","info":\#(info)}}"#.utf8)
    }

    private func parse(_ lines: [Data], initialModel: String? = "gpt-6-sol") -> CodexUsageParseResult {
        CodexUsageScanner.parse(lines: lines, sessionKey: key, initialModel: initialModel)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    func testCachedInputIsNotDoubleCounted() throws {
        let result = parse([turnContext("gpt-6-sol"),
                            tokenCount(input: 100, cached: 60, output: 20, reasoning: 7)])
        XCTAssertEqual(result.events.count, 1)
        let event = try XCTUnwrap(result.events.first)
        XCTAssertEqual(event.input, 40, "input − cached = uncached input")
        XCTAssertEqual(event.cacheRead, 60)
        XCTAssertEqual(event.output, 20, "reasoning не прибавляется к output повторно")
        XCTAssertEqual(event.total, 120, "total == input_tokens + output_tokens")
        XCTAssertEqual(event.sessionKey, key)
        XCTAssertFalse(event.isSidechain)
    }

    func testModelSwitchAndTimestampArePreserved() {
        let result = parse([
            turnContext("gpt-5.6-sol"),
            tokenCount(input: 100, cached: 0, output: 10, timestamp: "2026-10-06T10:00:00Z"),
            turnContext("gpt-6-astra"),
            tokenCount(input: 200, cached: 0, output: 20, timestamp: "2026-10-06T11:30:00Z"),
        ])
        XCTAssertEqual(result.events.map(\.model), ["gpt-5.6-sol", "gpt-6-astra"])
        XCTAssertEqual(result.events.map(\.t),
                       [date("2026-10-06T10:00:00Z"), date("2026-10-06T11:30:00Z")])
        XCTAssertEqual(result.model, "gpt-6-astra", "курсор получает последнюю модель")
    }

    func testInitialModelIsUsedUntilTurnContextOverrides() {
        let result = parse([tokenCount(input: 10, cached: 0, output: 5)], initialModel: "gpt-6-sol")
        XCTAssertEqual(result.events.map(\.model), ["gpt-6-sol"])
        XCTAssertEqual(result.model, "gpt-6-sol")
    }

    func testTokenCountWithoutKnownModelIsSkipped() {
        let result = CodexUsageScanner.parse(lines: [tokenCount(input: 10, cached: 0, output: 5)],
                                             sessionKey: key, initialModel: nil)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.stats.missingModel, 1)
    }

    func testFractionalSecondsTimestampIsExact() throws {
        let result = parse([tokenCount(input: 10, cached: 0, output: 5,
                                       timestamp: "2026-10-06T10:00:00.25Z")])
        let event = try XCTUnwrap(result.events.first)
        XCTAssertEqual(event.t.timeIntervalSince1970,
                       date("2026-10-06T10:00:00.25Z").timeIntervalSince1970, accuracy: 0.001)
    }

    func testMissingTimestampIsSkippedWithoutInventingTime() {
        let result = parse([tokenCount(input: 10, cached: 0, output: 5, timestamp: nil)])
        XCTAssertTrue(result.events.isEmpty, "никаких Date() для события без timestamp")
        XCTAssertEqual(result.stats.missingTimestamp, 1)
    }

    func testZeroUsageIsSkipped() {
        let result = parse([tokenCount(input: 0, cached: 0, output: 0)])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.stats.invalidUsage, 1)
    }

    func testInputSmallerThanCachedClampsToZero() throws {
        let result = parse([tokenCount(input: 10, cached: 40, output: 10)])
        let event = try XCTUnwrap(result.events.first)
        XCTAssertEqual(event.input, 0, "отрицательный uncached input невозможен")
        XCTAssertEqual(event.cacheRead, 40)
        XCTAssertEqual(event.total, 50)
    }

    func testContextsKeepTwoNewestPoints() {
        let result = parse([
            tokenCount(input: 100, cached: 0, output: 1, timestamp: "2026-10-06T10:00:00Z"),
            tokenCount(input: 200, cached: 0, output: 1, timestamp: "2026-10-06T10:01:00Z"),
            tokenCount(input: 300, cached: 0, output: 1, timestamp: "2026-10-06T10:02:00Z"),
        ])
        XCTAssertEqual(result.contexts.map(\.tokens), [200, 300], "input_tokens — рост контекста")
        XCTAssertEqual(result.contexts.map(\.t),
                       [Int64(date("2026-10-06T10:01:00Z").timeIntervalSince1970 * 1000),
                        Int64(date("2026-10-06T10:02:00Z").timeIntervalSince1970 * 1000)],
                       "внутренние таймстемпы — миллисекунды")
    }

    func testMalformedLineIsCountedNotThrown() {
        let result = parse([Data("not json".utf8),
                            tokenCount(input: 10, cached: 0, output: 5)])
        XCTAssertEqual(result.stats.malformed, 1)
        XCTAssertEqual(result.events.count, 1)
    }

    func testCumulativeTotalTokenUsageIsIgnored() {
        // total_token_usage (кумулятивный) не читается: только last_token_usage.
        let line = Data(#"{"timestamp":"2026-10-06T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9999,"cached_input_tokens":0,"output_tokens":9999}}}}"#.utf8)
        let result = parse([line])
        XCTAssertTrue(result.events.isEmpty)
    }

    func testUnknownEventTypeIsIgnoredSafely() {
        let line = Data(#"{"timestamp":"2026-10-06T10:00:00Z","type":"event_msg","payload":{"type":"brand_new_upstream_event"}}"#.utf8)
        var stats = CodexUsageParseStats()
        stats.malformed = 0
        let result = parse([line])
        XCTAssertEqual(result, CodexUsageParseResult(events: [], model: "gpt-6-sol",
                                                     contexts: [], stats: stats))
    }
}
