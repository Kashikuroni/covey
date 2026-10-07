import XCTest
import CoveyKit
@testable import covey

/// Чистый презентер карточек прогноза Codex (Task 5): стабильные ID,
/// error-режим для overflow/отрицательного headroom, различимая копия
/// calibrating/idle/stale, band только при наличии p50/p90, прочерки для
/// недоступных значений. Свежесть без живого ETA.
final class CodexForecastPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ bucket: String, _ key: CodexForecastWindowKey,
                        verdict: CodexForecastVerdict = .fits,
                        used: Double = 40, projected: Double = 60,
                        headroom: Double = 40, resetAt: Int64? = 1_800_003_600_000,
                        exhaustionAt: Int64? = 1_799_997_600_000,
                        p50: Double? = nil, p90: Double? = nil,
                        stale: Bool = false) -> CodexWindowForecast {
        CodexWindowForecast(bucketID: bucket, windowKey: key,
                            label: key == .primary ? "5h" : "7d",
                            verdict: verdict, usedPercent: used,
                            projectedPercent: projected, projectedP50: p50,
                            projectedP90: p90, headroomPercent: headroom,
                            resetAt: resetAt, exhaustionAt: exhaustionAt,
                            ratePercentPerHour: 3, sampleCount: 4, stale: stale)
    }

    func testTwoBucketsWithBothSlotsMakeFourCards() {
        let forecast = CodexForecast(windows: [
            window("codex", .primary), window("codex", .secondary),
            window("team", .primary), window("team", .secondary),
        ], updatedAt: 1)
        let cards = codexForecastPresentations(forecast, now: now)
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(Set(cards.map(\.id)),
                       ["codex:codex:primary", "codex:codex:secondary",
                        "codex:team:primary", "codex:team:secondary"],
                       "стабильный ID codex:<bucket>:<slot>")
    }

    func testOverflowAndNegativeHeadroomUseErrorTreatment() {
        let overflow = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, verdict: .overflow,
                                           headroom: -30)], updatedAt: 1), now: now)
        XCTAssertTrue(overflow[0].isError)
        let negative = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, verdict: .fits,
                                           headroom: -5)], updatedAt: 1), now: now)
        XCTAssertTrue(negative[0].isError, "отрицательный headroom — тоже error-режим")
        let calm = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary)], updatedAt: 1), now: now)
        XCTAssertFalse(calm[0].isError)
    }

    func testCalibratingIdleAndStaleHaveDistinctCopy() {
        let calibrating = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, verdict: .calibrating)],
                          updatedAt: 1), now: now)[0]
        let idle = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, verdict: .idle)],
                          updatedAt: 1), now: now)[0]
        let stale = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, stale: true)],
                          updatedAt: 1), now: now)[0]
        XCTAssertNotEqual(calibrating.status, idle.status)
        XCTAssertNotEqual(calibrating.status, stale.status)
        XCTAssertNotEqual(idle.status, stale.status)
        XCTAssertTrue(stale.staleBadge)
        XCTAssertNil(stale.exhaustion, "stale не намекает на живой ETA")
    }

    func testBandShownOnlyWhenBothPercentilesPresent() {
        let withBand = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, p50: 58, p90: 66)],
                          updatedAt: 1), now: now)[0]
        XCTAssertNotNil(withBand.band)
        XCTAssertTrue(withBand.band?.contains("58") ?? false)
        let half = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, p50: 58, p90: nil)],
                          updatedAt: 1), now: now)[0]
        XCTAssertNil(half.band, "полоса только с обеими границами")
    }

    func testResetLessWindowStaysVisibleWithDashes() {
        let cards = codexForecastPresentations(
            CodexForecast(windows: [window("codex", .primary, resetAt: nil,
                                           exhaustionAt: nil)], updatedAt: 1), now: now)
        XCTAssertEqual(cards.count, 1, "окно без reset остаётся видимым")
        XCTAssertEqual(cards[0].reset, "—")
        XCTAssertEqual(cards[0].exhaustion, "—")
    }

    func testLabelFallsBackToBucketID() {
        var forecast = CodexForecast(windows: [window("team", .primary)], updatedAt: 1)
        forecast.windows[0].label = ""
        let cards = codexForecastPresentations(forecast, now: now)
        XCTAssertEqual(cards[0].title, "team", "пустая метка → bucketID")
    }
}
