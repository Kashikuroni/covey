import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

/// ForecastAnalyticsMonitor + независимый analytics-цикл UsageMonitor:
/// GPT-аналитика собирается без GLM (выключен/нет ключа), transient сбой
/// чтения сохраняет последний хороший снимок, stop() гасит цикл, пустой
/// poll не поднимает revision.
@MainActor
final class ForecastAnalyticsMonitorTests: XCTestCase {
    private var base: String!
    private var codexRoot: String!
    private var rolloutPath: String!

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + UUID().uuidString
        codexRoot = base + "/sessions"
        try FileManager.default.createDirectory(atPath: codexRoot, withIntermediateDirectories: true)
        rolloutPath = try writeRollout()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: rolloutPath)
        try? FileManager.default.removeItem(atPath: base)
    }

    @discardableResult
    private func writeRollout(id: String = "r1", twoCounts: Bool = false) throws -> String {
        let path = codexRoot + "/rollout-\(id).jsonl"
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: now.addingTimeInterval(-60))
        let ts2 = f.string(from: now.addingTimeInterval(-30))
        func count(_ ts: String, input: Double) -> String {
            let line = #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":\#(input + 50)}}}}"#
            return line + "\n"
        }
        var text = #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"\#(id)","cwd":"/w/x","timestamp":"\#(ts)"}}"# + "\n"
            + #"{"type":"turn_context","payload":{"model":"gpt-6-sol"}}"# + "\n"
            + count(ts, input: 100)
        if twoCounts { text += count(ts2, input: 3000) }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeMonitor(store: QuotaSampleStore? = nil, agg: TokenAggregator? = nil,
                             usageInterval: TimeInterval = 60) -> UsageMonitor {
        let store = store ?? QuotaSampleStore(path: base + "/samples.json")
        let agg = agg ?? TokenAggregator(buckets: store.buckets)
        let codex = CodexTranscriptWatcher(sessionsRoot: codexRoot, aggregator: agg,
                                           store: store, includeExternal: true)
        let forecastMonitor = ForecastAnalyticsMonitor(store: store, aggregator: agg,
                                                       claudeWatcher: nil,
                                                       codexWatcher: codex,
                                                       glmConfig: GLMForecastConfig())
        return UsageMonitor(path: nil, legacyPath: nil,
                            fetchAccount: { Account(usageError: "off") },
                            fetchGLM: { GLMAccount(error: "no auth") },
                            usageInterval: usageInterval,
                            resolveCodex: { nil },
                            forecastMonitor: forecastMonitor,
                            forecastSessions: { [] })
    }

    // MARK: - Stage 2: quota ingestion

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func rateSnapshot(primary: Double, secondary: Double? = nil) -> CodexRateLimitsSnapshot {
        CodexRateLimitsSnapshot(buckets: ["codex": CodexRateLimitBucket(
            id: "codex", name: nil,
            primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                   window: UsageWindow(utilization: primary,
                                                       resetUnix: 1_800_003_600)),
            secondary: secondary.map {
                LabeledWindow(label: "7d", durationMinutes: 10_080,
                              window: UsageWindow(utilization: $0, resetUnix: 1_800_604_800))
            })])
    }

    /// Прогон полного цикла через UsageMonitor: ingest → settle → снимок.
    private func ingested(_ monitor: UsageMonitor,
                          _ snapshot: CodexRateLimitsSnapshot, at: Date) async {
        monitor.ingestRateLimits(snapshot)
        await settleForecastTasks()
        _ = at
    }

    /// Даём async-публикациям монитора доехать.
    private func settleForecastTasks() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<10 { await Task.yield() }
    }

    func testCodexQuotaRestartContinuesWithoutRecalibration() async throws {
        let storePath = base + "/quota.json"
        let store = QuotaSampleStore(path: storePath)
        let first = makeMonitor(store: store)
        try first.setEnabled(.glm, enabled: false)
        first.ingestRateLimits(rateSnapshot(primary: 20), now: t0)
        await settleForecastTasks()
        first.ingestRateLimits(rateSnapshot(primary: 25), now: t0.addingTimeInterval(60))
        await settleForecastTasks()
        XCTAssertNotNil(first.snapshot.codexForecast)

        // Рестарт: новый монитор над сохранённым стором.
        let reopened = QuotaSampleStore(path: storePath)
        let second = makeMonitor(store: reopened)
        second.ingestRateLimits(rateSnapshot(primary: 30), now: t0.addingTimeInterval(120))
        await settleForecastTasks()
        let window = second.snapshot.codexForecast?.windows.first { $0.windowKey == .primary }
        XCTAssertEqual(window?.sampleCount, 3, "история продолжилась, пересчёта с нуля нет")
        XCTAssertEqual(window?.usedPercent, 30)
    }

    func testSaveFailureLeavesPreviouslyPublishedForecastIntact() async throws {
        let storePath = base + "/quota-save.json"
        try FileManager.default.createDirectory(atPath: base + "/locked",
                                                withIntermediateDirectories: true)
        let store = QuotaSampleStore(path: storePath)
        let monitor = makeMonitor(store: store)
        monitor.ingestRateLimits(rateSnapshot(primary: 20), now: t0)
        await settleForecastTasks()
        let published = monitor.snapshot.codexForecast
        XCTAssertNotNil(published)

        // Ломаем сохранение: каталог стора — read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: base)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: base) }
        monitor.ingestRateLimits(rateSnapshot(primary: 40), now: t0.addingTimeInterval(60))
        await settleForecastTasks()
        XCTAssertEqual(monitor.snapshot.codexForecast, published,
                       "сбой save не затирает последний хороший прогноз")
    }

    func testCodexPartialUpdateSamplesMergedSnapshot() async throws {
        let store = QuotaSampleStore(path: base + "/partial.json")
        let monitor = makeMonitor(store: store)
        monitor.ingestRateLimits(rateSnapshot(primary: 20, secondary: 40), now: t0)
        await settleForecastTasks()
        monitor.ingestRateLimits(CodexRateLimitsSnapshot(buckets: ["codex":
            CodexRateLimitBucket(id: "codex", name: nil,
                primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                       window: UsageWindow(utilization: 25,
                                                           resetUnix: 1_800_003_600)),
                secondary: nil)]), now: t0.addingTimeInterval(60))
        await settleForecastTasks()
        func lastPercent(_ key: CodexForecastWindowKey) -> Double? {
            store.codexQuotaSeries(bucketID: "codex", windowKey: key,
                                   now: t0.addingTimeInterval(3600)).last?.usedPercent
        }
        _ = t0
        XCTAssertEqual(lastPercent(.primary), 25)
        XCTAssertEqual(lastPercent(.secondary), 40, "слот вне апдейта не перезаписан")
    }

    func testCodexForecastBecomesStaleWithoutNewSnapshot() async throws {
        let store = QuotaSampleStore(path: base + "/stale.json")
        let monitor = makeMonitor(store: store)
        monitor.ingestRateLimits(rateSnapshot(primary: 20), now: t0)
        await settleForecastTasks()
        XCTAssertFalse(monitor.snapshot.codexForecast?.windows.first?.stale ?? true)

        // +5 минут без новых событий: refreshAnalytics пересчитывает stale.
        await monitor.refreshAnalytics(now: t0.addingTimeInterval(300))
        XCTAssertTrue(monitor.snapshot.codexForecast?.windows.first?.stale ?? false,
                      "stale двигается настенными часами, без нового события")
        XCTAssertEqual(monitor.snapshot.codexForecast?.windows.first?.usedPercent, 20)
    }

    func testDisablingCodexInvalidatesPendingPublication() async throws {
        let store = QuotaSampleStore(path: base + "/disable.json")
        let monitor = makeMonitor(store: store)
        monitor.ingestRateLimits(rateSnapshot(primary: 20), now: t0)
        try monitor.setEnabled(.codex, enabled: false)
        await settleForecastTasks()
        XCTAssertNil(monitor.snapshot.codexForecast,
                     "выключение инвалидирует незавершённую публикацию")
        // История в сторе не стирается.
        XCTAssertFalse(store.codexQuotaSamples.isEmpty)
    }

    func testAnalyticsPollPublishesGPTWhenGLMIsDisabledAndUnauthed() async throws {
        let monitor = makeMonitor()
        try monitor.setEnabled(.glm, enabled: false)
        await monitor.refreshAnalytics()
        XCTAssertEqual(monitor.snapshot.forecastAnalytics?.models.map(\.model), ["gpt-6-sol"])
        XCTAssertEqual(monitor.snapshot.forecastAnalytics?.sessions.first?.source, .codex)
        XCTAssertNil(monitor.snapshot.glmForecast,
                     "нет GLM-квоты — нет и GLM-прогноза, аналитика при этом жива")
    }

    func testTransientCodexReadFailureKeepsLastGoodAnalytics() async throws {
        let monitor = makeMonitor()
        await monitor.refreshAnalytics()
        let before = monitor.snapshot.forecastAnalytics
        XCTAssertNotNil(before)

        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: rolloutPath)
        await monitor.refreshAnalytics()
        XCTAssertEqual(monitor.snapshot.forecastAnalytics, before,
                       "transient сбой чтения не затирает последний хороший снимок")
    }

    func testStopCancelsAnalyticsTask() async throws {
        let monitor = makeMonitor(usageInterval: 0.05)
        monitor.start()
        monitor.stop()
        // Появившийся ПОСЛЕ stop файл не должен быть прочитан отменённым циклом.
        try FileManager.default.removeItem(atPath: rolloutPath)
        try writeRollout(id: "r2")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(monitor.snapshot.forecastAnalytics,
                     "analytics-цикл погашен stop()")
    }

    func testOneUnreadableRolloutDoesNotFreezeThePoll() async throws {
        // Спека: ошибка Codex analytics не останавливает остальной конвейер.
        let bad = try writeRollout(id: "bad")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: bad)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: bad) }
        let monitor = makeMonitor()
        try monitor.setEnabled(.glm, enabled: false)
        await monitor.refreshAnalytics()
        XCTAssertEqual(monitor.snapshot.forecastAnalytics?.models.map(\.model),
                       ["gpt-6-sol"],
                       "хороший файл доехал, сбойный не заморозил публикацию")
    }

    func testCodexContextGrowthReachesLastContext() async throws {
        _ = try writeRollout(twoCounts: true)
        let monitor = makeMonitor()
        try monitor.setEnabled(.glm, enabled: false)
        await monitor.refreshAnalytics()
        let session = monitor.snapshot.forecastAnalytics?
            .sessions.first { $0.id == "codex:r1" }
        XCTAssertEqual(session?.contextTokens, 3000, "контекст Codex-сессии доезжает")
        XCTAssertEqual(session?.contextDeltaPerTurn, 2900,
                       "рост — разница двух последних точек (3000 − 100)")
    }

    func testNoOpPollDoesNotBumpRevision() async throws {
        let monitor = makeMonitor()
        await monitor.refreshAnalytics()
        let revision = monitor.snapshot.revision
        await monitor.refreshAnalytics()
        XCTAssertEqual(monitor.snapshot.revision, revision,
                       "повторный poll с теми же данными — no-op")
    }
}
