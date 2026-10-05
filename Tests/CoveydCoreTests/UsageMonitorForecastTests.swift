import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

@MainActor
final class UsageMonitorForecastTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/-Users-x-proj",
                                                withIntermediateDirectories: true)
    }

    private func glmJSON(used: Double, resetInHours: Double) -> Data {
        let reset = Int64((Date().addingTimeInterval(resetInHours * 3600)).timeIntervalSince1970 * 1000)
        return #"{"data":{"level":"max","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":\#(used / 10),"usage":1000,"currentValue":\#(used),"remaining":\#(1000 - used),"nextResetTime":\#(reset)}]}}"#.data(using: .utf8)!
    }

    private func transcript(total: Int) throws {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = #"{"type":"assistant","timestamp":"\#(ts)","isSidechain":false,"sessionId":"uuid-1","message":{"model":"glm-4.6","usage":{"input_tokens":\#(total),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        try line.write(toFile: dir + "/-Users-x-proj/uuid-1.jsonl", atomically: true, encoding: .utf8)
    }

    func testForecastAppearsInSnapshotAfterGLMPoll() async throws {
        try transcript(total: 50_000)
        let store = QuotaSampleStore(path: nil)
        let agg = TokenAggregator()
        let watcher = TranscriptWatcher(projectsRoot: dir, aggregator: agg, store: store,
                                        includeExternal: true,
                                        coveyClaudeSessions: { [("uuid-1", "fix-auth", true)] })
        var fetchCount = 0
        let monitor = UsageMonitor(
            path: nil, legacyPath: nil,
            fetchAccount: { Account(usageError: "off") },
            fetchGLM: {
                fetchCount += 1
                // Сырой ответ парсер не примет в тесте напрямую; в обход сети:
                return GLMAccount(quota: parseGLMQuota(self.glmJSON(used: Double(100 * fetchCount),
                                                                  resetInHours: 5))!)
            },
            usageInterval: 0.01,
            resolveCodex: { nil },
            forecastStore: store, transcriptWatcher: watcher, forecastAggregator: agg,
            glmSessions: { [("uuid-1", "fix-auth", true)] })
        await monitor.refresh(.glm)
        await monitor.refresh(.glm)   // второй опрос: дебаунс подтверждает вердикт
        let f = monitor.snapshot.glmForecast
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.agents.first?.name, "fix-auth")
        XCTAssertEqual(f?.fiveHours?.total ?? 0, 1000, accuracy: 1)
        XCTAssertFalse(f?.fiveHourSeries.isEmpty ?? true, "сэмплы поллинга попали в серию")
    }

    func testVerdictDebounceNeedsTwoPolls() async throws {
        try transcript(total: 50_000)
        let store = QuotaSampleStore(path: nil)
        let agg = TokenAggregator()
        let watcher = TranscriptWatcher(projectsRoot: dir, aggregator: agg, store: store,
                                        includeExternal: true, coveyClaudeSessions: { [] })
        var used = 0.0
        let monitor = UsageMonitor(
            path: nil, legacyPath: nil,
            fetchAccount: { Account(usageError: "off") },
            fetchGLM: {
                used += 100
                return GLMAccount(quota: parseGLMQuota(self.glmJSON(used: used, resetInHours: 0.5))!)
            },
            usageInterval: 0.01, resolveCodex: { nil },
            forecastStore: store, transcriptWatcher: watcher, forecastAggregator: agg,
            glmSessions: { [] })
        await monitor.refresh(.glm)
        // Один опрос: вердикт ещё не подтверждён — публикуется .calibrating-заглушка или прошлый.
        // Второй опрос с тем же характером данных: вердикт подтверждён.
        await monitor.refresh(.glm)
        XCTAssertNotNil(monitor.snapshot.glmForecast?.fiveHours?.verdict)
    }

    func testPersistedFactorsSurviveRestartAndFirstPoll() async throws {
        // Спека §4.1: рестарт демона не сбрасывает калибровку. Факторы сеются
        // из стора и публикуются в первом же прогнозе: транскрипта нет —
        // калибровке не по чему пересчитать, сеянное не должно затираться
        // пустым дефолтом.
        var p = PersistedFactors()
        p.peak = 0.06; p.offPeak = 0.05
        p.peakAt = Int64(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1000)
        p.offPeakAt = p.peakAt
        let store = QuotaSampleStore(path: nil)
        store.setFactors(p)
        let monitor = UsageMonitor(
            path: nil, legacyPath: nil,
            fetchAccount: { Account(usageError: "off") },
            fetchGLM: { GLMAccount(quota: parseGLMQuota(self.glmJSON(used: 100, resetInHours: 5))!) },
            usageInterval: 0.01, resolveCodex: { nil },
            forecastStore: store)
        await monitor.refresh(.glm)
        await monitor.refresh(.glm)   // квота неизменна → дельт, меняющих факторы, нет
        let f = monitor.snapshot.glmForecast
        XCTAssertEqual(f?.factorPeak ?? 0, 0.06, accuracy: 1e-9)
        XCTAssertEqual(f?.factorOffPeak ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertNotNil(f?.factorPeakAt, "возраст калибровки тоже переживает рестарт")
    }

    func testForecastDisabledWhenStoreIsNil() async throws {
        let monitor = UsageMonitor(path: nil, legacyPath: nil,
                                   fetchAccount: { Account(usageError: "off") },
                                   fetchGLM: { GLMAccount(error: "no auth") },
                                   usageInterval: 0.01, resolveCodex: { nil })
        await monitor.refresh(.glm)
        XCTAssertNil(monitor.snapshot.glmForecast, "без forecastStore монитор ведёт себя как раньше")
    }
}
