import XCTest
import CoveyKit
@testable import CoveydCore
@testable import covey

/// Сквозная проверка этапа 2: полный двухбакетный снапшот → частичный
/// апдейт через минуту → рестарт монитора/стора → третий апдейт. Точные
/// счётчики сэмплов, rate, миллисекунды reset, rollover и stale.
@MainActor
final class CodexQuotaForecastIntegrationTests: XCTestCase {
    private var base: String!
    private var storePath: String!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + UUID().uuidString
        storePath = base + "/usage-samples.json"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
        try? FileManager.default.removeItem(atPath: storePath + ".bak")
    }

    private func snapshot(primary: Double, secondary: Double?,
                          reset: Int64 = 1_800_003_600) -> CodexRateLimitsSnapshot {
        CodexRateLimitsSnapshot(buckets: [
            "codex": CodexRateLimitBucket(
                id: "codex", name: nil,
                primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                       window: UsageWindow(utilization: primary,
                                                           resetUnix: reset)),
                secondary: secondary.map {
                    LabeledWindow(label: "7d", durationMinutes: 10_080,
                                  window: UsageWindow(utilization: $0,
                                                      resetUnix: 1_800_604_800))
                }),
            "team": CodexRateLimitBucket(
                id: "team", name: "Team",
                primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                       window: UsageWindow(utilization: primary + 5,
                                                           resetUnix: reset)),
                secondary: nil),
        ])
    }

    private func partial(primary: Double) -> CodexRateLimitsSnapshot {
        CodexRateLimitsSnapshot(buckets: ["codex": CodexRateLimitBucket(
            id: "codex", name: nil,
            primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                   window: UsageWindow(utilization: primary,
                                                       resetUnix: 1_800_003_600)),
            secondary: nil)])
    }

    @MainActor
    private func makeMonitor(store: QuotaSampleStore) -> UsageMonitor {
        let aggregator = TokenAggregator(buckets: store.buckets)
        let forecastMonitor = ForecastAnalyticsMonitor(
            store: store, aggregator: aggregator,
            claudeWatcher: nil, codexWatcher: nil,
            glmConfig: GLMForecastConfig(),
            codexConfig: CodexForecastConfig(marginPercent: 15))
        return UsageMonitor(path: base + "/usage.json", legacyPath: nil,
                            fetchAccount: { Account(usageError: "off") },
                            fetchGLM: { GLMAccount(error: "no auth") },
                            resolveCodex: { nil },
                            forecastMonitor: forecastMonitor,
                            forecastSessions: { [] })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<10 { await Task.yield() }
    }

    func testMergeRestartProjectionAndRollover() async throws {
        let store = QuotaSampleStore(path: storePath)
        let monitor = makeMonitor(store: store)

        // Полный снапшот + частичный через минуту: merged перед семплированием.
        monitor.ingestRateLimits(snapshot(primary: 20, secondary: 40), now: t0)
        await settle()
        monitor.ingestRateLimits(partial(primary: 25), now: t0.addingTimeInterval(60))
        await settle()

        let codex = store.codexQuotaSeries(bucketID: "codex", windowKey: .primary,
                                           now: t0.addingTimeInterval(3600))
        XCTAssertEqual(codex.count, 2)
        XCTAssertEqual(codex.last?.usedPercent, 25, "частичный апдейт доехал merged")
        XCTAssertEqual(codex.last?.resetAt, 1_800_003_600_000, "reset в миллисекундах")
        let team = store.codexQuotaSeries(bucketID: "team", windowKey: .primary,
                                          now: t0.addingTimeInterval(3600))
        XCTAssertEqual(team.count, 2,
                       "merged снапшот несёт базовые слоты — семплируются оба раза")
        let secondary = store.codexQuotaSeries(bucketID: "codex", windowKey: .secondary,
                                               now: t0.addingTimeInterval(3600))
        XCTAssertEqual(secondary.count, 2)
        XCTAssertEqual(secondary.map(\.usedPercent), [40, 40],
                       "базовый secondary переезджает без изменений")

        // Опубликованный прогноз: 4 окна (codex×2 + team×1), канонический порядок.
        let published = monitor.snapshot.codexForecast
        XCTAssertEqual(published?.windows.count, 3)
        XCTAssertEqual(published?.windows.map { "\($0.bucketID):\($0.windowKey.rawValue)" },
                       ["codex:primary", "codex:secondary", "team:primary"])

        // Рестарт: монитор и стор пересозданы, третий апдейт продолжает.
        let reopened = QuotaSampleStore(path: storePath)
        let restarted = makeMonitor(store: reopened)
        restarted.ingestRateLimits(partial(primary: 30), now: t0.addingTimeInterval(120))
        await settle()
        let continued = reopened.codexQuotaSeries(bucketID: "codex", windowKey: .primary,
                                                  now: t0.addingTimeInterval(3600))
        XCTAssertEqual(continued.count, 3, "история пережила рестарт")
        XCTAssertEqual(continued.map(\.usedPercent), [20, 25, 30])
        // Rate по минутным шагам +5 = 300%/ч; окно в overflow.
        let window = restarted.snapshot.codexForecast?.windows.first {
            $0.bucketID == "codex" && $0.windowKey == .primary }
        XCTAssertEqual(window?.ratePercentPerHour ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(window?.verdict, .overflow)
        XCTAssertEqual(window?.sampleCount, 3)

        // Rollover: новый reset с меньшим процентом — калибровка заново,
        // отрицательного rate нет.
        restarted.ingestRateLimits(
            snapshot(primary: 5, secondary: 2, reset: 1_800_360_000),
            now: t0.addingTimeInterval(180))
        await settle()
        let rolled = restarted.snapshot.codexForecast?.windows.first {
            $0.bucketID == "codex" && $0.windowKey == .primary }
        XCTAssertEqual(rolled?.verdict, .calibrating)
        XCTAssertEqual(rolled?.ratePercentPerHour, 0)

        // Stale: +5 минут без наблюдений — модель stale, алерты молчат.
        await restarted.refreshAnalytics(now: t0.addingTimeInterval(300 + 180))
        XCTAssertTrue(restarted.snapshot.codexForecast?.windows.first {
            $0.bucketID == "codex" && $0.windowKey == .primary }?.stale ?? false)
        let (alerts, marks) = codexPredictiveAlerts(
            forecast: restarted.snapshot.codexForecast,
            config: GLMForecastConfigSection(),
            notified: [:], now: t0.addingTimeInterval(480))
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertTrue(marks.isEmpty)
    }
}
