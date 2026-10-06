import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

/// Сквозной прогон Stage 1: rollout-файл → CodexTranscriptWatcher →
/// агрегатор → ForecastAnalyticsBuilder → UsageSnapshot.forecastAnalytics →
/// персистентность → рестарт без дублирования. GLM выключен и без ключа:
/// аналитика собирается независимо (спека «Проверка этапа 1»).
@MainActor
final class CodexForecastAnalyticsIntegrationTests: XCTestCase {
    private var base: String!
    private var root: String!
    private var storePath: String!

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + UUID().uuidString
        root = base + "/sessions"
        storePath = base + "/usage-samples.json"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
        try? FileManager.default.removeItem(atPath: storePath + ".bak")
    }

    private func writeRollout() throws {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        let dir = "\(root!)/\(f.string(from: now))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-120))
        func count(_ model: String, input: Double, cached: Double, output: Double) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":7,"total_tokens":\#(input + output)}}}}"# + "\n"
        }
        let text = #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"e2e","cwd":"/w/e2e","timestamp":"\#(ts)"}}"# + "\n"
            + #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"# + "\n"
            + count("5.6", input: 1000, cached: 600, output: 200)
            + #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"# + "\n"
            + count("6", input: 500, cached: 100, output: 50)
        try text.write(toFile: "\(dir)/rollout-e2e.jsonl", atomically: true, encoding: .utf8)
    }

    private func makeMonitor(store: QuotaSampleStore) -> UsageMonitor {
        let aggregator = TokenAggregator(buckets: store.buckets)
        let watcher = CodexTranscriptWatcher(sessionsRoot: root, aggregator: aggregator,
                                             store: store, includeExternal: true)
        let forecastMonitor = ForecastAnalyticsMonitor(store: store, aggregator: aggregator,
                                                       claudeWatcher: nil,
                                                       codexWatcher: watcher,
                                                       glmConfig: GLMForecastConfig())
        return UsageMonitor(path: nil, legacyPath: nil,
                            fetchAccount: { Account(usageError: "off") },
                            fetchGLM: { GLMAccount(error: "no auth") },
                            resolveCodex: { nil },
                            forecastMonitor: forecastMonitor,
                            forecastSessions: { [] })
    }

    func testRolloutToAnalyticsAndRestart() async throws {
        try writeRollout()

        let first = makeMonitor(store: QuotaSampleStore(path: storePath))
        try first.setEnabled(.glm, enabled: false)
        await first.refreshAnalytics()

        let analytics = first.snapshot.forecastAnalytics
        XCTAssertEqual(analytics?.models.map(\.model).sorted(), ["gpt-5.6-sol", "gpt-6-astra"])
        XCTAssertEqual(analytics?.sessions.first?.source, .codex)
        XCTAssertEqual(analytics?.sessions.first?.external, true)
        XCTAssertNil(first.snapshot.glmForecast, "GLM выключен — прогноза нет, аналитика есть")
        // Нормализация cached-инпута: uncached = input − cached.
        let total = analytics?.models.reduce(0.0) { $0 + $1.window.total } ?? 0
        XCTAssertEqual(total, 1750, accuracy: 0.001, "(1000−600)+600+200 + (500−100)+100+50")

        let persistedBefore = QuotaSampleStore(path: storePath).buckets
        XCTAssertFalse(persistedBefore.isEmpty, "вёдра доехали до диска")

        // Рестарт: новый монитор над тем же стором не дублирует данные.
        let restarted = makeMonitor(store: QuotaSampleStore(path: storePath))
        try restarted.setEnabled(.glm, enabled: false)
        await restarted.refreshAnalytics()
        let persistedAfter = QuotaSampleStore(path: storePath).buckets
        XCTAssertEqual(persistedAfter, persistedBefore)
        XCTAssertEqual(restarted.snapshot.forecastAnalytics, analytics,
                       "снимок после рестарта эквивалентен")
    }
}
