import XCTest
import Foundation
@testable import CoveydCore

@MainActor
final class TokenUsageScannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000)
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + UUID().uuidString + "/projects/-Users-x-proj"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ text: String, ageMinutes: Double = 0) throws {
        let path = dir + "/" + name
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: t0 - ageMinutes * 60],
                                              ofItemAtPath: path)
    }

    private func assistantLine(total: Int, minutesAgo: Double, model: String = "glm-4.6",
                               session: String = "uuid-1") -> String {
        let ts = ISO8601DateFormatter().string(from: t0 - minutesAgo * 60)
        return #"{"type":"assistant","timestamp":"\#(ts)","isSidechain":false,"sessionId":"\#(session)","message":{"model":"\#(model)","usage":{"input_tokens":\#(total),"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"#
    }

    // MARK: parse

    func testParsesAssistantLineAndSkipsOthers() {
        let text = [
            #"{"type":"user","message":{}}"#,
            assistantLine(total: 100, minutesAgo: 1),
            #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":5}}}"#,
            assistantLine(total: 50, minutesAgo: 0.5, session: "uuid-2"),
        ].joined(separator: "\n") + "\n"
        let events = TokenUsageScanner.parse(Data(text.utf8), fallbackDate: t0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].sessionKey, "uuid-1")
        XCTAssertEqual(events[0].input, 100)
        XCTAssertEqual(events[0].cacheRead, 3)
        XCTAssertEqual(events[1].sessionKey, "uuid-2")
    }

    func testPartialTrailingLineIsIgnored() {
        let full = assistantLine(total: 10, minutesAgo: 1) + "\n"
        let partial = #"{"type":"assistant","timestamp":"2026"#
        let events = TokenUsageScanner.parse(Data((full + partial).utf8), fallbackDate: t0)
        XCTAssertEqual(events.count, 1, "частичная хвостовая строка не учитывается")
    }

    func testLineWithoutUsageIsSkipped() {
        let text = #"{"type":"assistant","timestamp":"2026-10-02T00:00:00Z","message":{"model":"glm-4.6"}}"# + "\n"
        XCTAssertTrue(TokenUsageScanner.parse(Data(text.utf8), fallbackDate: t0).isEmpty)
    }

    // MARK: activeFiles

    func testActiveFilesReturnsOnlyRecentJsonl() throws {
        let root = NSTemporaryDirectory() + UUID().uuidString
        let proj = root + "/-Users-x"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        for (name, age) in [("a.jsonl", 1.0), ("b.jsonl", 60.0)] {
            try (assistantLine(total: 1, minutesAgo: 1) + "\n").write(toFile: proj + "/" + name,
                                                                      atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: t0 - age * 60],
                                                  ofItemAtPath: proj + "/" + name)
        }
        try "x".write(toFile: proj + "/notes.txt", atomically: true, encoding: .utf8)
        let files = TokenUsageScanner.activeFiles(projectsRoot: root, cutoff: t0 - 600, now: t0)
        XCTAssertEqual(files.map { ($0 as NSString).lastPathComponent }, ["a.jsonl"])
    }

    // MARK: TranscriptWatcher

    private func makeWatcher(agg: TokenAggregator, store: QuotaSampleStore,
                             includeExternal: Bool = true) -> TranscriptWatcher {
        TranscriptWatcher(projectsRoot: (dir as NSString).deletingLastPathComponent,
                          aggregator: agg, store: store, includeExternal: includeExternal,
                          coveyClaudeSessions: { [("uuid-1", "fix-auth", true)] })
    }

    func testWatcherReadsIncrementallyAndSurvivesPartialLine() throws {
        let agg = TokenAggregator(); let store = QuotaSampleStore(path: nil)
        let watcher = makeWatcher(agg: agg, store: store)
        let path = dir + "/uuid-1.jsonl"
        try (assistantLine(total: 10, minutesAgo: 1) + "\n").write(toFile: path, atomically: true,
                                                                   encoding: .utf8)
        watcher.poll(now: t0)
        XCTAssertEqual(agg.totals(since: .distantPast).total, 16, accuracy: 0.001)

        let partial = #"{"type":"assistant","timestamp":"1970-01-22T00"#
        let appender = FileHandle(forWritingAtPath: path)!
        try appender.seekToEnd()
        appender.write(Data(partial.utf8))
        try? appender.close()
        watcher.poll(now: t0)
        XCTAssertEqual(agg.totals(since: .distantPast).total, 16, accuracy: 0.001,
                       "частичная строка не доезжает")

        let completer = FileHandle(forWritingAtPath: path)!
        try completer.seekToEnd()
        completer.write(Data((#":00:00Z","message":{"model":"glm-4.6","usage":{"input_tokens":7}}}"# + "\n").utf8))
        try? completer.close()
        watcher.poll(now: t0)
        XCTAssertEqual(agg.totals(since: .distantPast).total, 23, accuracy: 0.001, "дописанная строка дочитана")
        XCTAssertEqual(store.offsets[path] ?? 0,
                       try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0,
                       "офсет = размер файла после целых строк")
    }

    func testWatcherSkipsExternalWhenDisabled() throws {
        let agg = TokenAggregator(); let store = QuotaSampleStore(path: nil)
        let watcher = makeWatcher(agg: agg, store: store, includeExternal: false)
        try (assistantLine(total: 10, minutesAgo: 1, session: "ext-9") + "\n")
            .write(toFile: dir + "/ext-9.jsonl", atomically: true, encoding: .utf8)
        watcher.poll(now: t0)
        XCTAssertEqual(agg.totals(since: .distantPast).total, 0, accuracy: 0.001)
    }

    func testWatcherResetsOnTruncation() throws {
        let agg = TokenAggregator(); let store = QuotaSampleStore(path: nil)
        let watcher = makeWatcher(agg: agg, store: store)
        let path = dir + "/uuid-1.jsonl"
        try (assistantLine(total: 10, minutesAgo: 2) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        watcher.poll(now: t0)
        try Data().write(to: URL(fileURLWithPath: path))  // урезали
        try (assistantLine(total: 3, minutesAgo: 1) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        watcher.poll(now: t0)
        XCTAssertEqual(agg.totals(since: .distantPast).total, 25, accuracy: 0.001,
                       "урезание сбрасывает офсет: перечитано 9 поверх уже учтённых 16")
    }
}
