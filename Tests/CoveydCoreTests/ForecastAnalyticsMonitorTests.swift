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
