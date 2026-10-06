import XCTest
@testable import CoveydCore
import CoveyKit

/// CodexTranscriptWatcher: discovery восьми дней, инкрементальное чтение с
/// бюджетом 8 MiB, матчинг с Covey-сессиями (cwd + ±120 c), курсоры и
/// truncation без удвоения. Спека — «Discovery, backfill и идентификация
/// сессий».
final class CodexTranscriptWatcherTests: XCTestCase {
    private var root: String!
    private var storePath: String!
    private var store: QuotaSampleStore!
    private var aggregator: TokenAggregator!
    private let now = Date()

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + UUID().uuidString
        root = base + "/sessions"
        storePath = base + "/usage-samples.json"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        store = QuotaSampleStore(path: storePath)
        aggregator = TokenAggregator()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: storePath)
        try? FileManager.default.removeItem(atPath: storePath + ".bak")
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    @discardableResult
    private func makeRollout(dayOffset: Int, id: String, cwd: String,
                             metaTimestamp: Date? = nil,
                             tokenCounts: [(input: Double, cached: Double, output: Double)] = [],
                             model: String = "gpt-6-sol",
                             mtime: Date? = nil,
                             extra: String = "") throws -> String {
        let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy/MM/dd"
        let dir = "\(root!)/\(f.string(from: day))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-\(id).jsonl"
        var text = #"{"timestamp":"\#(iso(metaTimestamp ?? now))","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","timestamp":"\#(iso(metaTimestamp ?? now))"}}"# + "\n"
        text += #"{"type":"turn_context","payload":{"model":"\#(model)"}}"# + "\n"
        for (i, tc) in tokenCounts.enumerated() {
            let ts = now.addingTimeInterval(TimeInterval(-3600 + i * 60))
            text += #"{"timestamp":"\#(iso(ts))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(tc.input),"cached_input_tokens":\#(tc.cached),"output_tokens":\#(tc.output),"reasoning_output_tokens":0,"total_tokens":\#(tc.input + tc.output)}}}}"# + "\n"
        }
        text += extra
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        return path
    }

    private func makeWatcher(store: QuotaSampleStore? = nil,
                             aggregator: TokenAggregator? = nil,
                             includeExternal: Bool = true,
                             maxBytes: Int = 8 * 1024 * 1024) -> CodexTranscriptWatcher {
        CodexTranscriptWatcher(sessionsRoot: root, aggregator: aggregator ?? self.aggregator!,
                               store: store ?? self.store!, includeExternal: includeExternal,
                               maxBytesPerPoll: maxBytes)
    }

    private func totals() -> GLMTokenUsage {
        aggregator!.totals(since: .distantPast)
    }

    // MARK: - discovery

    func testBackfillDiscoverySpansTodayThroughDayMinusSeven() throws {
        try makeRollout(dayOffset: 0, id: "today", cwd: "/w/now",
                        tokenCounts: [(input: 10, cached: 0, output: 5)])
        try makeRollout(dayOffset: -7, id: "week", cwd: "/w/week",
                        tokenCounts: [(input: 100, cached: 0, output: 50)])
        try makeRollout(dayOffset: -8, id: "older", cwd: "/w/old",
                        tokenCounts: [(input: 5000, cached: 0, output: 5000)],
                        mtime: now.addingTimeInterval(-3600),   // неактивный — вне окна
                        )
        _ = try makeWatcher().poll(now: now, sessions: [])
        let t = totals()
        XCTAssertEqual(t.input, 110, "today и day-7 включены, day-8 — нет")
        XCTAssertEqual(t.output, 55)
    }

    func testActiveDayMinusEightRolloutIsStillDiscovered() throws {
        try makeRollout(dayOffset: -8, id: "longrun", cwd: "/w/long",
                        tokenCounts: [(input: 42, cached: 0, output: 8)],
                        mtime: now.addingTimeInterval(-120))
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().input, 42,
                       "долго живущая сессия не теряется из-за старой даты каталога")
    }

    // MARK: - matching

    func testCoveySessionMatchRequiresCwdAndCreationProximity() throws {
        let meta = now.addingTimeInterval(-30)
        try makeRollout(dayOffset: 0, id: "m1", cwd: "/w/matched", metaTimestamp: meta,
                        tokenCounts: [(input: 1, cached: 0, output: 1)])
        try makeRollout(dayOffset: 0, id: "m2", cwd: "/w/other-cwd", metaTimestamp: meta,
                        tokenCounts: [(input: 2, cached: 0, output: 2)])
        try makeRollout(dayOffset: 0, id: "m3", cwd: "/w/matched",
                        metaTimestamp: now.addingTimeInterval(-600),
                        tokenCounts: [(input: 4, cached: 0, output: 4)])
        let sessions = [
            ForecastSessionIdentity(name: "work", cwd: "/w/matched", agent: "codex",
                                    created: Int64(meta.timeIntervalSince1970)),
        ]
        _ = try makeWatcher().poll(now: now, sessions: sessions)
        XCTAssertEqual(store.sessionMetadata["codex:m1"]?.external, false,
                       "cwd совпал, создание в пределах 120 c")
        XCTAssertEqual(store.sessionMetadata["codex:m2"]?.external, true, "чужой cwd")
        XCTAssertEqual(store.sessionMetadata["codex:m3"]?.external, true,
                       "создание дальше 120 секунд")
        XCTAssertEqual(store.codexCursors.values.map(\.sessionKey).sorted(),
                       ["codex:m1", "codex:m2", "codex:m3"],
                       "ключ — codex:<session-meta-id> независимо от матчинга")
    }

    // MARK: - cursors

    func testRestartDoesNotDuplicateAndKeepsModel() throws {
        let path = try makeRollout(dayOffset: 0, id: "s1", cwd: "/w/s1",
                                   tokenCounts: [(input: 100, cached: 0, output: 50)])
        _ = try makeWatcher().poll(now: now, sessions: [])
        let before = totals()
        try store.save()

        let reloadedStore = QuotaSampleStore(path: storePath)
        let reloadedAggregator = TokenAggregator(buckets: reloadedStore.buckets)
        _ = try makeWatcher(store: reloadedStore, aggregator: reloadedAggregator)
            .poll(now: now, sessions: [])
        XCTAssertEqual(reloadedAggregator.totals(since: .distantPast), before,
                       "повторный poll не дублирует события")
        XCTAssertEqual(reloadedStore.codexCursors[path]?.model, "gpt-6-sol")
    }

    func testExcludedExternalSessionBackfillsWhenReenabled() throws {
        try makeRollout(dayOffset: 0, id: "ext", cwd: "/w/ext",
                        tokenCounts: [(input: 100, cached: 0, output: 50)])
        _ = try makeWatcher(includeExternal: false).poll(now: now, sessions: [])
        XCTAssertNil(store.codexCursors.values.first,
                     "курсор для исключённого файла не создаётся")
        XCTAssertEqual(totals().total, 0)

        _ = try makeWatcher(includeExternal: true).poll(now: now, sessions: [])
        XCTAssertGreaterThan(totals().total, 0, "повторное включение backfill-ит историю")
    }

    func testPartialTailIsReadExactlyOnce() throws {
        let full = #"{"timestamp":"\#(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}"# + "\n"
        let path = try makeRollout(dayOffset: 0, id: "tail", cwd: "/w/tail", extra: String(full.dropLast(7)))
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().total, 0, "незавершённая строка не ingest-ится")

        // Файл перезаписан целиком: тот же префикс + завершённая строка.
        try makeRollout(dayOffset: 0, id: "tail", cwd: "/w/tail", extra: full)
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().input, 10, "дочитывается ровно один раз")
    }

    func testFileGrowthIngestsOnlyNewLines() throws {
        let path = try makeRollout(dayOffset: 0, id: "grow", cwd: "/w/grow",
                                   tokenCounts: [(input: 10, cached: 0, output: 5)])
        _ = try makeWatcher().poll(now: now, sessions: [])
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        let ts2 = iso(now.addingTimeInterval(-60))
        handle.write(Data(#"{"timestamp":"\#(ts2)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1500}}}}"#.utf8) + Data([0x0A]))
        try handle.close()
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().input, 1010, "второй poll читает только прирост")
    }

    func testTruncationDoesNotDuplicateLiveBuckets() throws {
        let path = try makeRollout(dayOffset: 0, id: "trunc", cwd: "/w/tr",
                                   tokenCounts: [(input: 100, cached: 0, output: 50)])
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().input, 100)

        // Файл усечён и перезаписан меньшей историей.
        try makeRollout(dayOffset: 0, id: "trunc", cwd: "/w/tr",
                        tokenCounts: [(input: 7, cached: 0, output: 3)])
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().input, 7,
                       "truncation сбрасывает живые вёдра сессии и перечитывает")
    }

    func testMissingRootIsEmptySourceNotError() throws {
        let watcher = CodexTranscriptWatcher(
            sessionsRoot: NSTemporaryDirectory() + "definitely-not-here-\(UUID().uuidString)",
            aggregator: aggregator, store: store, includeExternal: true)
        let report = try watcher.poll(now: now, sessions: [])
        XCTAssertEqual(report, CodexWatcherReport(bytesRead: 0, filesRead: 0,
                                                  backfillRemaining: false,
                                                  stats: CodexUsageParseStats()))
    }

    func testPermissionFailureThrows() throws {
        let path = try makeRollout(dayOffset: 0, id: "perm", cwd: "/w/perm",
                                   tokenCounts: [(input: 10, cached: 0, output: 5)])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        XCTAssertThrowsError(try makeWatcher().poll(now: now, sessions: []),
                             "source-level сбой чтения — throwable (ledger ruling)")
    }

    func testEventsOlderThanEightDaysAreAbsentAfterPoll() throws {
        let old = now.addingTimeInterval(-9 * 24 * 3600)
        let day = Calendar.current.date(byAdding: .day, value: -9, to: now)!
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
        let dir = "\(root!)/\(f.string(from: day))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let line = #"{"timestamp":"\#(iso(old))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9999,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":10000}}}}"# + "\n"
        try (#"{"timestamp":"\#(iso(old))","type":"session_meta","payload":{"id":"old","cwd":"/w/old","timestamp":"\#(iso(old))"}}"# + "\n" +
             #"{"type":"turn_context","payload":{"model":"gpt-6-sol"}}"# + "\n" + line)
            .write(toFile: "\(dir)/rollout-old.jsonl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)],
                                              ofItemAtPath: "\(dir)/rollout-old.jsonl")
        _ = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertEqual(totals().total, 0, "события старше 8 дней отсекаются prune")
    }

    // MARK: - budget

    func testBackfillReadsAtMostEightMiBPerPoll() throws {
        // Один файл ~9 MiB: бюджет обрывает чтение, остаток — в следующем poll.
        let dir = root!
        let path = "\(dir)/rollout-big.jsonl"
        try (#"{"timestamp":"\#(iso(now))","type":"session_meta","payload":{"id":"big","cwd":"/w/big","timestamp":"\#(iso(now))"}}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        let ts = iso(now)
        let line = Data(#"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}"#.utf8) + Data([0x0A])
        let lineCount = (9 * 1024 * 1024) / line.count + 10
        try handle.seekToEnd()
        for _ in 0..<lineCount { handle.write(line) }
        try handle.close()
        let report = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertLessThanOrEqual(report.bytesRead, 8 * 1024 * 1024)
        XCTAssertTrue(report.backfillRemaining, "незавершённый backfill продолжится")
        let second = try makeWatcher().poll(now: now, sessions: [])
        XCTAssertFalse(second.backfillRemaining, "хвост дочитан вторым poll-ом")
    }
}
