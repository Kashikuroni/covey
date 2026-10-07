import XCTest
import CoveyKit
@testable import covey

/// Codex-предиктивные алерты (Task 6): лестница overflow → ETA<60 → ETA<15,
/// imminent для tight/fits, тишина для calibrating/idle/stale, независимые
/// маркеры бакетов/слотов, новый reset — новое окно уведомлений.
/// Rate-limit snapshot авторитетен: локальные GPT-сессии не требуются.
final class CodexPredictiveLimitAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var config: GLMForecastConfigSection { GLMForecastConfigSection() }

    private func window(_ bucket: String = "codex", slot: CodexForecastWindowKey = .primary,
                        verdict: CodexForecastVerdict = .overflow,
                        resetAt: Int64? = 1_800_003_600_000,
                        exhaustionInMin: Double? = 30,
                        stale: Bool = false) -> CodexWindowForecast {
        CodexWindowForecast(bucketID: bucket, windowKey: slot, label: "5h",
                            verdict: verdict, usedPercent: 90,
                            projectedPercent: 110, projectedP50: nil, projectedP90: nil,
                            headroomPercent: verdict == .overflow ? -10 : 8,
                            resetAt: resetAt,
                            exhaustionAt: exhaustionInMin.map {
                                Int64(now.timeIntervalSince1970 * 1000) + Int64($0 * 60_000)
                            },
                            ratePercentPerHour: 10, sampleCount: 3, stale: stale)
    }

    private func forecast(_ windows: [CodexWindowForecast]) -> CodexForecast {
        CodexForecast(windows: windows, updatedAt: 1)
    }

    private func fire(_ windows: [CodexWindowForecast],
                      notified: [String: Int64] = [:])
        -> (alerts: [LimitAlert], notified: [String: Int64]) {
        codexPredictiveAlerts(forecast: forecast(windows), config: config,
                              notified: notified, now: now)
    }

    func testOverflowEscalatesThroughLadderLevels() {
        // Уровень = ступень по ТЕКУЩЕМУ ETA: ≥60 → 0, <60 → 1, <15 → 2.
        // Первый огонь при ETA 30 сразу ставит level 1.
        let first = fire([window(exhaustionInMin: 90)])
        XCTAssertEqual(first.alerts.count, 1, "level 0: обычный overflow")
        let again = fire([window(exhaustionInMin: 70)], notified: first.notified)
        XCTAssertEqual(again.alerts.count, 0, "та же ступень молчит")
        let third = fire([window(exhaustionInMin: 50)], notified: first.notified)
        XCTAssertEqual(third.alerts.count, 1, "ETA<60 — эскалация на level 1")
        let fourth = fire([window(exhaustionInMin: 10)], notified: third.notified)
        XCTAssertEqual(fourth.alerts.count, 1, "ETA<15 — level 2")
        let fifth = fire([window(exhaustionInMin: 8)], notified: fourth.notified)
        XCTAssertEqual(fifth.alerts.count, 0, "вершина лестницы достигнута")
    }

    func testLadderIsMonotonicDownward() {
        // После критического уровня более мягкий не досылаем: ETA вырос
        // (темп упал) — level 1 после level 2 молчит.
        let critical = fire([window(exhaustionInMin: 10)])
        XCTAssertEqual(critical.alerts.count, 1, "сразу level 2")
        let milder = fire([window(exhaustionInMin: 50)], notified: critical.notified)
        XCTAssertEqual(milder.alerts.count, 0, "level 1 после level 2 не приходит")
    }

    func testImminentAlertForTightAndFits() {
        let tight = fire([window(verdict: .tight, exhaustionInMin: 10)])
        XCTAssertEqual(tight.alerts.count, 1, "tight с ETA<20 — imminent")
        let again = fire([window(verdict: .tight, exhaustionInMin: 9)],
                         notified: tight.notified)
        XCTAssertEqual(again.alerts.count, 0, "imminent — один раз")
        let fits = fire([window(verdict: .fits, exhaustionInMin: 5)])
        XCTAssertEqual(fits.alerts.count, 1, "fits тоже получает imminent")
    }

    func testCalibratingAndIdleAreSilent() {
        XCTAssertEqual(fire([window(verdict: .calibrating)]).alerts.count, 0)
        XCTAssertEqual(fire([window(verdict: .idle)]).alerts.count, 0)
    }

    func testStaleForecastIsSilentAndKeepsMarkers() {
        let existing: [String: Int64] = ["codex:predict:codex:primary:1800003600000:overflow:0": 7]
        let result = fire([window(stale: true)], notified: existing)
        XCTAssertEqual(result.alerts.count, 0, "stale не уведомляет")
        XCTAssertEqual(result.notified, existing, "маркеры не тронуты")
    }

    func testNewResetPermitsNewAlert() {
        let first = fire([window(exhaustionInMin: 30)])
        XCTAssertEqual(first.alerts.count, 1)
        let newWindow = fire([window(resetAt: 1_800_014_400_000, exhaustionInMin: 30)],
                             notified: first.notified)
        XCTAssertEqual(newWindow.alerts.count, 1, "новый reset — новое окно алертов")
    }

    func testBucketsAndWindowsHaveIndependentMarkers() {
        let sameReset = Int64(1_800_003_600_000)
        let primary = fire([
            window("codex", slot: .primary, resetAt: sameReset, exhaustionInMin: 30),
            window("codex", slot: .secondary, resetAt: sameReset, exhaustionInMin: 30),
            window("team", slot: .primary, resetAt: sameReset, exhaustionInMin: 30),
        ])
        XCTAssertEqual(primary.alerts.count, 3,
                       "одинаковые метки/reset не схлопывают алерты")
        // Повтор после первого огня: все три маркера стоят — тишина.
        let repeat_ = fire([
            window("codex", slot: .primary, resetAt: sameReset, exhaustionInMin: 28),
            window("codex", slot: .secondary, resetAt: sameReset, exhaustionInMin: 28),
            window("team", slot: .primary, resetAt: sameReset, exhaustionInMin: 28),
        ], notified: primary.notified)
        XCTAssertEqual(repeat_.alerts.count, 0)
    }

    func testNoLocalSessionsRequired() {
        // Чистая функция: ни агрегатора, ни сессий на входе — только прогноз.
        let result = fire([window(exhaustionInMin: 30)])
        XCTAssertFalse(result.alerts.isEmpty)
    }
}
