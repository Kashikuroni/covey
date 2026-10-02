import XCTest
import Foundation
@testable import CoveydCore

final class QuotaSampleStoreTests: XCTestCase {
    private func sample(minuteAgo: Int, fiveUsed: Double, now: Date) -> QuotaSample {
        QuotaSample(t: Int64((now - TimeInterval(minuteAgo * 60)).timeIntervalSince1970 * 1000),
                    fiveUsed: fiveUsed, fiveReset: 0, weekUsed: 0, weekReset: 0)
    }

    func testSameMinuteSamplesMergeKeepingLast() {
        let now = Date(timeIntervalSince1970: 1_800_000)  // выровнен на минуту
        let store = QuotaSampleStore(path: nil)
        store.append(sample(minuteAgo: 0, fiveUsed: 10, now: now))
        store.append(sample(minuteAgo: 0, fiveUsed: 12, now: now))
        store.append(sample(minuteAgo: 1, fiveUsed: 8, now: now))
        XCTAssertEqual(store.minuteSeries(now: now, minutes: 10).map(\.fiveUsed), [8, 12])
    }

    func testMinuteSamplesOlderThanTwoHoursFoldIntoFiveMinuteBucketsKeepingLast() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let store = QuotaSampleStore(path: nil)
        // 3 часостарых сэмпла в одном 5-мин ведре + свежий.
        store.append(sample(minuteAgo: 125, fiveUsed: 100, now: now))
        store.append(sample(minuteAgo: 124, fiveUsed: 110, now: now))
        store.append(sample(minuteAgo: 123, fiveUsed: 120, now: now))
        store.append(sample(minuteAgo: 1, fiveUsed: 200, now: now))
        XCTAssertTrue(store.minuteSeries(now: now, minutes: 120).allSatisfy { $0.fiveUsed == 200 },
                      "старые минутные ушли из минутной серии")
        let week = store.weekSeries(now: now, days: 7)
        XCTAssertEqual(week.first?.fiveUsed, 120, "в 5-мин ведре остаётся ПОСЛЕДНИЙ сэмпл (used кумулятивен)")
        XCTAssertEqual(week.last?.fiveUsed, 200)
    }

    func testFiveMinuteBucketsOlderThanSevenDaysAreDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let store = QuotaSampleStore(path: nil)
        store.append(sample(minuteAgo: 8 * 24 * 60, fiveUsed: 1, now: now))
        store.append(sample(minuteAgo: 10, fiveUsed: 2, now: now))
        XCTAssertEqual(store.weekSeries(now: now, days: 7).count, 1)
    }

    func testPersistenceRoundTrip() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let now = Date(timeIntervalSince1970: 1_800_000)
        var factors = PersistedFactors(); factors.peak = 0.00002; factors.recentPeak = [0.00002]
        let store = QuotaSampleStore(path: path)
        store.append(sample(minuteAgo: 0, fiveUsed: 5, now: now))
        store.setBuckets([TokenBucket(m: 0, s: "s1", model: "glm-4.6", x: false,
                                      input: 1, output: 2, cacheCreation: 0, cacheRead: 3)])
        store.setOffset("/tmp/a.jsonl", 999)
        store.setFactors(factors)
        try store.save()
        let reloaded = QuotaSampleStore(path: path)
        XCTAssertEqual(reloaded.minuteSeries(now: now, minutes: 10).map(\.fiveUsed), [5])
        XCTAssertEqual(reloaded.buckets.count, 1)
        XCTAssertEqual(reloaded.offsets["/tmp/a.jsonl"], 999)
        XCTAssertEqual(reloaded.factors.peak, 0.00002)
    }

    func testCorruptFileStartsEmpty() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let store = QuotaSampleStore(path: path)
        XCTAssertEqual(store.minuteSeries(now: Date(), minutes: 10), [])
    }
}
