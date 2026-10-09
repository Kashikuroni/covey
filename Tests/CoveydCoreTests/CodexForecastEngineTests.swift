import XCTest
import CoveyKit
@testable import CoveydCore

/// CodexForecastEngine: чистая проекция rate-limit окон из истории сэмплов.
/// Формулы — спека этапа 2: projected = used + rate·h, headroom = 100 −
/// projected, exhaustion = now + (100−used)/rate. Изоляция: бакеты/слоты
/// никогда не смешиваются, GPT-токены и GLM-факторы движку не нужны.
final class CodexForecastEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)   // :00 минуты
    private var store: QuotaSampleStore!

    override func setUpWithError() throws {
        store = QuotaSampleStore(path: nil)
    }

    private func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Снапшот одного видимого бакета «codex» с заданной свежей утилизацией.
    private func snapshot(primary: Double, primaryReset: Int64 = 1_800_003_600,
                          primaryDuration: Int? = 300,
                          secondary: Double? = nil) -> CodexRateLimitsSnapshot {
        CodexRateLimitsSnapshot(buckets: ["codex": CodexRateLimitBucket(
            id: "codex", name: nil,
            primary: LabeledWindow(label: "5h", durationMinutes: primaryDuration,
                                   window: UsageWindow(utilization: primary,
                                                       resetUnix: primaryReset)),
            secondary: secondary.map {
                LabeledWindow(label: "7d", durationMinutes: 10_080,
                              window: UsageWindow(utilization: $0, resetUnix: 1_800_604_800))
            })])
    }

    /// Кладёт в стор серию: usage каждые 60 c, начиная с `startMinutes` назад.
    private func feed(_ usage: [(minutesAgo: Int, used: Double)],
                      resetUnix: Int64 = 1_800_003_600, slot: CodexForecastWindowKey = .primary) {
        for point in usage {
            let now = base.addingTimeInterval(TimeInterval(-point.minutesAgo * 60))
            var snap = snapshot(primary: point.used, primaryReset: resetUnix)
            if slot == .secondary {
                snap = CodexRateLimitsSnapshot(buckets: ["codex": CodexRateLimitBucket(
                    id: "codex", name: nil, primary: nil,
                    secondary: LabeledWindow(label: "7d", durationMinutes: 10_080,
                                             window: UsageWindow(utilization: point.used,
                                                                 resetUnix: resetUnix)))])
            }
            store.appendCodexRateLimits(snap, now: now)
        }
    }

    private func build(_ snap: CodexRateLimitsSnapshot? = nil,
                       now: Date? = nil,
                       config: CodexForecastConfig = CodexForecastConfig()) -> CodexForecast {
        CodexForecastEngine.build(snapshot: snap ?? snapshot(primary: 50),
                                  store: store, now: now ?? base, config: config)
    }

    private func window(_ forecast: CodexForecast, _ key: CodexForecastWindowKey = .primary,
                        bucket: String = "codex") -> CodexWindowForecast {
        forecast.windows.first { $0.bucketID == bucket && $0.windowKey == key }!
    }

    // MARK: - калибровка / idle

    func testFirstSampleReturnsCalibratingWithCountOne() {
        feed([(5, 10)])
        let w = window(build())
        XCTAssertEqual(w.verdict, .calibrating)
        XCTAssertEqual(w.sampleCount, 1)
    }

    func testTwoEqualSamplesReturnIdleWithoutETA() {
        feed([(5, 10), (4, 10)])
        let w = window(build())
        XCTAssertEqual(w.verdict, .idle)
        XCTAssertEqual(w.ratePercentPerHour, 0)
        XCTAssertNil(w.exhaustionAt)
    }

    // MARK: - формулы

    func testSteadyShortWindowProjectsByMedianRecentRate() {
        // 10% → 20% → 30% минутными шагами: каждый интервал +10 пунктов/мин
        // = 600%/ч, медиана 600; до reset 1 час.
        feed([(5, 10), (4, 20), (3, 30)])
        let w = window(build(snapshot(primary: 30)))
        XCTAssertEqual(w.ratePercentPerHour, 600, accuracy: 1e-9)
        XCTAssertEqual(w.usedPercent, 30)
        XCTAssertEqual(w.projectedPercent, 630, accuracy: 1e-9, "30 + 600·1")
        XCTAssertEqual(w.headroomPercent, -530, accuracy: 1e-9)
        XCTAssertEqual(w.verdict, .overflow)
        let eta = try! XCTUnwrap(w.exhaustionAt)
        XCTAssertEqual(eta - ms(base), 7 * 60 * 1000, accuracy: 60_000,
                       "(100−30)/600 = 7 минут")
        XCTAssertEqual(w.sampleCount, 3)
        XCTAssertFalse(w.stale)
    }

    func testPublishesResetSegmentSeriesForEachSlot() throws {
        feed([(5, 10), (4, 20), (3, 30)])
        let forecast = build(snapshot(primary: 30))
        let primary = try XCTUnwrap(forecast.windows.first {
            $0.bucketID == "codex" && $0.windowKey == .primary })
        let series = try XCTUnwrap(primary.series, "движок публикует историю окна")
        XCTAssertEqual(series.map(\.usedPercent), [10, 20, 30],
                       "series — фактические проценты в хронологическом порядке")
        XCTAssertEqual(series.map(\.t), series.map(\.t).sorted())
        XCTAssertTrue(series.allSatisfy { (0...104).contains($0.usedPercent) })
        XCTAssertEqual(series.last?.usedPercent, primary.usedPercent)
    }

    func testOverLimitUsageOverflowsWithoutPastETA() {
        feed([(5, 104), (4, 105)])
        let w = window(build(snapshot(primary: 105)))
        XCTAssertEqual(w.verdict, .overflow)
        XCTAssertEqual(w.usedPercent, 105)
        let eta = w.exhaustionAt
        XCTAssertNotNil(eta)
        XCTAssertGreaterThanOrEqual(eta!, ms(base), "exhaustion никогда не в прошлом")
    }

    func testVerdictBoundariesAreDeterministic() {
        // Прямое управление rate: два сэмпла минутным шагом (+10 пунктов) =
        // 600%/ч. projected = used + 600·resetInH.
        func verdict(used: Double, resetInH: Double) -> CodexForecastVerdict {
            feed([(3, used - 10), (2, used)])
            let resetS = Int64(Double(ms(base)) / 1000 + resetInH * 3600)
            let snap = snapshot(primary: used, primaryReset: resetS)
            return window(build(snap)).verdict
        }
        // projected ровно 100 → overflow: 40 + 600·0.1 = 100.
        XCTAssertEqual(verdict(used: 40, resetInH: 0.1), .overflow)
        // headroom ровно margin (15): 55 + 600·0.05 = 85 → fits.
        XCTAssertEqual(verdict(used: 55, resetInH: 0.05), .fits)
        // headroom ниже margin: 50 + 600·0.08 = 98 → headroom 2 → tight.
        XCTAssertEqual(verdict(used: 50, resetInH: 0.08), .tight)
        // headroom ровно 30: 40 + 600·0.05 = 70 → fits (underuse — строго выше 30).
        XCTAssertEqual(verdict(used: 40, resetInH: 0.05), .fits)
        // headroom 31: 39 + 600·0.05 = 69 → underuse.
        XCTAssertEqual(verdict(used: 39, resetInH: 0.05), .underuse)
    }

    func testUnknownDurationFallsBackBySlot() {
        // primary без duration → короткая стратегия; secondary → длинная.
        feed([(30, 10), (3, 15), (2, 20)])
        feed([(30, 10), (3, 15), (2, 20)], resetUnix: 1_800_604_800, slot: .secondary)
        var snap = snapshot(primary: 20, primaryDuration: nil, secondary: 20)
        snap.buckets["codex"]?.secondary = LabeledWindow(
            label: "7d", durationMinutes: nil,
            window: UsageWindow(utilization: 20, resetUnix: 1_800_604_800))
        let forecast = build(snap)
        XCTAssertEqual(window(forecast).verdict, .overflow,
                       "короткая стратегия видит свежие интервалы")
        let secondary = window(forecast, .secondary)
        XCTAssertNotNil(secondary.projectedP50, "длинная стратегия даёт полосу")
    }

    // MARK: - reset / gap / stale

    func testResetDoesNotProduceNegativeRate() {
        feed([(5, 90), (4, 5)])
        let w = window(build(snapshot(primary: 5, primaryReset: 1_800_003_600)))
        XCTAssertEqual(w.ratePercentPerHour, 0)
        XCTAssertEqual(w.verdict, .calibrating, "падение = новый сегмент, калибровка заново")
    }

    func testGapOverThreeMinutesIsExcluded() {
        // 10% → (пауза 5 минут) → 40%: интервал через гэп не считается.
        feed([(10, 10), (5, 40)])
        let w = window(build(snapshot(primary: 40)))
        XCTAssertEqual(w.verdict, .calibrating,
                       "единственный интервал — через гэп 5 минут, отброшен")
    }

    func testStaleFlagAdvancesWithWallClockWithoutNewSamples() {
        feed([(3, 10), (2, 20), (1, 30)])
        // Свежий опрос: не stale.
        XCTAssertFalse(window(build(snapshot(primary: 30))).stale)
        // Теперь без новых сэмплов прошло 5 минут: stale.
        let later = base.addingTimeInterval(300)
        let w = window(build(snapshot(primary: 30), now: later))
        XCTAssertTrue(w.stale, "флаг пересчитывается от настенных часов")
        XCTAssertEqual(w.usedPercent, 30, "последнее наблюдение остаётся видимым")
    }

    func testBucketsAndSlotsNeverMix() {
        feed([(5, 10), (4, 20)])
        var other = snapshot(primary: 90)
        other.buckets["team"] = CodexRateLimitBucket(
            id: "team", name: "Team",
            primary: LabeledWindow(label: "5h", durationMinutes: 300,
                                   window: UsageWindow(utilization: 90, resetUnix: 1_800_003_600)),
            secondary: nil)
        let forecast = build(other)
        XCTAssertEqual(window(forecast).verdict, .overflow,
                       " codex:primary с историей")
        let team = forecast.windows.first { $0.bucketID == "team" }
        XCTAssertEqual(team?.verdict, .calibrating, "team без своей истории — калибровка")
    }

    // MARK: - недельное окно

    func testWeeklyWindowUsesEMABandAndDiscardsPreviousResetIntervals() {
        // Длинная серия с устойчивым темпом (~100%/ч) в ОДНОМ reset-сегменте.
        var points: [(Int, Double)] = []
        for i in 0..<30 { points.append((i + 2, Double(100 - i * 10 / 6))) }
        feed(points, resetUnix: 1_800_604_800, slot: .secondary)
        var snap = snapshot(primary: 50, secondary: 90)
        snap.buckets["codex"]?.secondary = LabeledWindow(
            label: "7d", durationMinutes: 10_080,
            window: UsageWindow(utilization: 90, resetUnix: 1_800_604_800))
        let secondary = window(build(snap), .secondary)
        XCTAssertNotNil(secondary.projectedP50)
        XCTAssertGreaterThanOrEqual(secondary.projectedP90!, secondary.projectedP50!)
        XCTAssertGreaterThan(secondary.ratePercentPerHour, 0)

        // Reset сменился: прежние интервалы отброшены — калибровка заново.
        var afterReset = snapshot(primary: 50, secondary: 5)
        afterReset.buckets["codex"]?.secondary = LabeledWindow(
            label: "7d", durationMinutes: 10_080,
            window: UsageWindow(utilization: 5, resetUnix: 1_860_480_000))
        feed([(1, 5)], resetUnix: 1_860_480_000, slot: .secondary)
        let resetWindow = window(build(afterReset), .secondary)
        XCTAssertEqual(resetWindow.verdict, .calibrating,
                       "интервалы прошлого reset-окна не продлевают калибровку")
    }
}
