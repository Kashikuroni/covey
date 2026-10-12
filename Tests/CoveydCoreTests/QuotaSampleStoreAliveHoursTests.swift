import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

final class QuotaSampleStoreAliveHoursTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 1_792_000_000) }
    private var hour: Int64 { Int64(now.timeIntervalSince1970 * 1000) / 3_600_000 * 3_600_000 }

    func testInsertsZeroForAbsentHour() {
        let store = QuotaSampleStore(path: nil)
        store.markAliveHours([hour], now: now)
        XCTAssertEqual(store.hourTotals.first?.t, hour)
        XCTAssertEqual(store.hourTotals.first?.used, 0)
    }

    func testDoesNotClobberExistingPoint() {
        let store = QuotaSampleStore(path: nil)
        store.upsertHourTotals([GLMSeriesPoint(t: hour, used: 500)], now: now)
        store.markAliveHours([hour], now: now)
        XCTAssertEqual(store.hourTotals.first?.used, 500)
    }

    func testRealPointOverwritesEarlierMark() {
        let store = QuotaSampleStore(path: nil)
        store.markAliveHours([hour], now: now)
        store.upsertHourTotals([GLMSeriesPoint(t: hour, used: 500)], now: now)
        XCTAssertEqual(store.hourTotals.first?.used, 500)
    }

    func testPrunesBeyond90Days() {
        let store = QuotaSampleStore(path: nil)
        let old = hour - Int64(91 * 86_400_000)
        store.markAliveHours([old, hour], now: now)
        XCTAssertEqual(store.hourTotals.map(\.t), [hour])
    }
}
