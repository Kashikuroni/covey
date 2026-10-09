import XCTest
import Foundation
@testable import covey

/// Длительности до сброса: сутки+ — в днях («3d 18h»), ровные сутки — «3d»,
/// меньше суток — часы/минуты, под часом — минуты (как раньше).
final class ForecastENDurationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000)

    func testOverADayShowsDaysAndHours() {
        let reset = now.addingTimeInterval(90 * 3600 + 41 * 60)
        XCTAssertEqual(ForecastEN.duration(from: now, to: reset), "3d 18h")
    }

    func testExactDaysShowNoHours() {
        let reset = now.addingTimeInterval(72 * 3600)
        XCTAssertEqual(ForecastEN.duration(from: now, to: reset), "3d")
    }

    func testUnderADayKeepsHoursAndMinutes() {
        let reset = now.addingTimeInterval(5 * 3600 + 41 * 60)
        XCTAssertEqual(ForecastEN.duration(from: now, to: reset), "5h 41m")
    }

    func testUnderAnHourKeepsMinutesOnly() {
        let reset = now.addingTimeInterval(41 * 60)
        XCTAssertEqual(ForecastEN.duration(from: now, to: reset), "41m")
    }

    // MARK: - exhausts label: сегодня — только время, другой день — дата

    func testSameDayEtaShowsTimeOnly() {
        let eta = now.addingTimeInterval(40 * 60)
        XCTAssertEqual(ForecastText.exhausts(eta, now: now),
                       "exhausts ~" + ForecastText.time.string(from: eta),
                       "5h-окно исчерпывается сегодня — время само говорит за себя")
    }

    func testOtherDayEtaShowsWeekdayAndDate() {
        // +2 суток: попадает на другой день — ветка etaDateTime (день недели,
        // дата, время), а не голое время.
        let eta = now.addingTimeInterval(48 * 3600 + 31 * 60)
        XCTAssertEqual(ForecastText.exhausts(eta, now: now),
                       "exhausts ~" + ForecastText.etaDateTime.string(from: eta))
        XCTAssertNotEqual(ForecastText.exhausts(eta, now: now),
                          "exhausts ~" + ForecastText.time.string(from: eta))
        // «день недели, дата, время» — с запятыми (разделителями формата).
        XCTAssertTrue(ForecastText.etaDateTime.string(from: eta).contains(","))
    }
}
