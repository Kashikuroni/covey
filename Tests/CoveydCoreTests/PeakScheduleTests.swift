import XCTest
import Foundation
@testable import CoveydCore

final class PeakScheduleTests: XCTestCase {
    // 2026-10-02 — пятница. 14:00 UTC+8 = 06:00 UTC.
    private func d(_ isoUTC: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: isoUTC)!
    }

    func testPeakWindowBoundaries() {
        // Пт 2026-10-02: пик 06:00–10:00 UTC.
        XCTAssertTrue(PeakSchedule.isPeak(at: d("2026-10-02T06:00:00Z")))      // ровно начало
        XCTAssertTrue(PeakSchedule.isPeak(at: d("2026-10-02T09:59:59Z")))
        XCTAssertFalse(PeakSchedule.isPeak(at: d("2026-10-02T10:00:00Z")))     // ровно конец — уже офф
        XCTAssertFalse(PeakSchedule.isPeak(at: d("2026-10-02T05:59:59Z")))
    }

    func testWeekendIsOffPeak() {
        // Сб 2026-10-03 и Вс 2026-10-04 — целиком офф-пик, включая «пиковые часы».
        XCTAssertFalse(PeakSchedule.isPeak(at: d("2026-10-03T07:00:00Z")))
        XCTAssertFalse(PeakSchedule.isPeak(at: d("2026-10-04T07:00:00Z")))
    }

    func testSegmentsAcrossPeakBoundary() {
        // Чт 2026-10-01 04:00 UTC (12:00 UTC+8, офф) → пт 2026-10-02 01:00 UTC
        // (09:00 UTC+8). Сегменты: офф до чт 06:00 UTC (14:00 UTC+8) = 2ч;
        // пик чт 06:00–10:00 UTC = 4ч; офф с 10:00 UTC до пт 01:00 UTC = 15ч.
        let segs = PeakSchedule.segments(from: d("2026-10-01T04:00:00Z"), to: d("2026-10-02T01:00:00Z"))
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0].peak, false); XCTAssertEqual(segs[0].duration, 2 * 3600, accuracy: 1)
        XCTAssertEqual(segs[1].peak, true);  XCTAssertEqual(segs[1].duration, 4 * 3600, accuracy: 1)
        XCTAssertEqual(segs[2].peak, false); XCTAssertEqual(segs[2].duration, 15 * 3600, accuracy: 1)
        let total = segs.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(total, d("2026-10-02T01:00:00Z").timeIntervalSince(d("2026-10-01T04:00:00Z")), accuracy: 1)
    }

    func testNextFlip() {
        XCTAssertEqual(PeakSchedule.nextFlip(after: d("2026-10-02T05:00:00Z")), d("2026-10-02T06:00:00Z"))
        XCTAssertEqual(PeakSchedule.nextFlip(after: d("2026-10-02T06:00:00Z")), d("2026-10-02T10:00:00Z"))
        // Пт 11:00 UTC — уже офф-пик; следующая смена — пн 2026-10-05 06:00 UTC
        // (выходные пропускаются).
        XCTAssertEqual(PeakSchedule.nextFlip(after: d("2026-10-02T11:00:00Z")), d("2026-10-05T06:00:00Z"))
    }
}
