import XCTest
import Foundation
import CoveyKit
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
        store.setCWD("-Users-x-proj", cwd: "/Users/x/proj")
        store.setFactors(factors)
        try store.save()
        let reloaded = QuotaSampleStore(path: path)
        XCTAssertEqual(reloaded.minuteSeries(now: now, minutes: 10).map(\.fiveUsed), [5])
        XCTAssertEqual(reloaded.buckets.count, 1)
        XCTAssertEqual(reloaded.offsets["/tmp/a.jsonl"], 999)
        XCTAssertEqual(reloaded.cwds["-Users-x-proj"], "/Users/x/proj", "cwd переживает рестарт")
        XCTAssertEqual(reloaded.factors.peak, 0.00002)
    }

    func testCodexCursorAndMetadataSurviveRoundTrip() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let rollout = "/tmp/rollout-s1.jsonl"
        let store = QuotaSampleStore(path: path)
        store.setCodexCursor(
            CodexUsageCursor(
                offset: 42,
                model: "gpt-6-sol",
                sessionKey: "codex:s1",
                contexts: [CodexContextPoint(tokens: 100, t: 7)]),
            for: rollout)
        store.setSessionMetadata(
            ForecastSessionMetadata(source: .codex, cwd: "/work/app", external: true),
            for: "codex:s1")

        try store.save()
        let restored = QuotaSampleStore(path: path)

        XCTAssertEqual(restored.codexCursors[rollout]?.offset, 42)
        XCTAssertEqual(restored.codexCursors[rollout]?.model, "gpt-6-sol")
        XCTAssertEqual(restored.codexCursors[rollout]?.contexts,
                       [CodexContextPoint(tokens: 100, t: 7)])
        XCTAssertEqual(restored.sessionMetadata["codex:s1"]?.source, .codex)
        XCTAssertEqual(restored.sessionMetadata["codex:s1"]?.cwd, "/work/app")
    }

    func testCodexCursorCanBeRemovedWithoutTouchingMetadata() {
        let store = QuotaSampleStore(path: nil)
        store.setCodexCursor(
            CodexUsageCursor(offset: 42, model: nil, sessionKey: "codex:s1", contexts: []),
            for: "/tmp/rollout-s1.jsonl")
        store.setSessionMetadata(
            ForecastSessionMetadata(source: .codex, cwd: nil, external: true),
            for: "codex:s1")

        store.removeCodexCursor(for: "/tmp/rollout-s1.jsonl")

        XCTAssertTrue(store.codexCursors.isEmpty)
        XCTAssertNotNil(store.sessionMetadata["codex:s1"])
    }

    func testLegacyForecastFileDefaultsNewCollectionsToEmpty() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let legacy = """
        {"minute":[],"fiveMin":[],"buckets":[],"offsets":{},"cwds":{},
         "gaps":[],"factors":{"recentPeak":[],"recentOffPeak":[]}}
        """
        try Data(legacy.utf8).write(to: URL(fileURLWithPath: path))

        let restored = QuotaSampleStore(path: path)

        XCTAssertTrue(restored.codexCursors.isEmpty)
        XCTAssertTrue(restored.sessionMetadata.isEmpty)
    }

    func testUpsertModelDaysReplacesTodayAndPrunesYear() {
        let store = QuotaSampleStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dayMs: (Int) -> Int64 = { ago in
            Int64(Calendar.current.startOfDay(
                for: now.addingTimeInterval(TimeInterval(-ago) * 86_400)).timeIntervalSince1970 * 1000)
        }
        // Из опроса приезжают последние 8 дней; вчерашнее значение обновляется.
        store.upsertModelDays((0...8).map { GLMDayUsage(t: dayMs($0), models: ["glm-4.6": 10]) },
                              now: now)
        XCTAssertEqual(store.modelDays.count, 9)
        store.upsertModelDays([GLMDayUsage(t: dayMs(1), models: ["glm-4.6": 99])], now: now)
        XCTAssertEqual(store.modelDays.first { $0.t == dayMs(1) }?.models["glm-4.6"], 99,
                       "день перезаписывается, а не дублируется")
        XCTAssertEqual(store.modelDays.count, 9)
        // Год спустя старые дни выпадают.
        let nextYear = now.addingTimeInterval(366 * 86_400)
        store.upsertModelDays([GLMDayUsage(t: dayMs(0), models: [:])], now: nextYear)
        XCTAssertTrue(store.modelDays.allSatisfy {
            $0.t >= Int64(nextYear.addingTimeInterval(-365 * 86_400).timeIntervalSince1970 * 1000)
        }, "дневные вёдра старше года прунятся")
    }

    // MARK: Этап 0 — накопление истории (roadmap docs/forecast_metrics_roadmap.md)

    func testSessionLedgerUpsertMergesAndArchives() {
        let store = QuotaSampleStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let t0 = Int64(now.addingTimeInterval(-2 * day).timeIntervalSince1970 * 1000)
        var rec = SessionCostRecord(firstSeen: t0, lastSeen: t0,
                                    byModel: ["glm-4.6": 100], external: true, cwd: "/x/proj",
                                    usage: ["glm-4.6": GLMTokenUsage(input: 100)])
        store.upsertSessions(["uuid-1": rec], now: now)
        XCTAssertEqual(store.sessionLedger["uuid-1"]?.byModel["glm-4.6"], 100)
        // Покопонентный usage: монотонный мерж по каждой компоненте.
        XCTAssertEqual(store.sessionLedger["uuid-1"]?.usage?["glm-4.6"]?.input ?? 0, 100,
                       accuracy: 0.001)

        // Вёдра прунятся — снапшот меньше пожизненного тотала не откатывает его.
        rec.byModel = ["glm-4.6": 150]
        rec.lastSeen = Int64(now.timeIntervalSince1970 * 1000)
        store.upsertSessions(["uuid-1": rec], now: now)
        XCTAssertEqual(store.sessionLedger["uuid-1"]?.byModel["glm-4.6"], 150)
        rec.byModel = ["glm-4.6": 120]
        store.upsertSessions(["uuid-1": rec], now: now)
        XCTAssertEqual(store.sessionLedger["uuid-1"]?.byModel["glm-4.6"], 150,
                       "тоталы растут монотонно")

        // Молчание >3 дней без данных — сессия финализируется в архив.
        store.upsertSessions([:], now: now.addingTimeInterval(4 * day))
        XCTAssertNil(store.sessionLedger["uuid-1"])
        XCTAssertEqual(store.sessionArchive.count, 1)
        XCTAssertEqual(store.sessionArchive.first?.value.byModel["glm-4.6"], 150,
                       "архив хранит финальный тотал")
    }

    func testHourTotalsUpsertReplacesSameHourAndPrunes() {
        let store = QuotaSampleStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: Int64 = 3_600_000
        let h0 = Int64(now.timeIntervalSince1970 * 1000) / hour * hour
        store.upsertHourTotals([GLMSeriesPoint(t: h0, used: 10)], now: now)
        store.upsertHourTotals([GLMSeriesPoint(t: h0, used: 12),
                                GLMSeriesPoint(t: h0 + hour, used: 5)], now: now)
        XCTAssertEqual(store.hourTotals.count, 2)
        XCTAssertEqual(store.hourTotals.first?.used, 12, "тот же час перезаписывается")
        store.upsertHourTotals([], now: now.addingTimeInterval(91 * 86_400))
        XCTAssertTrue(store.hourTotals.isEmpty, "старше 90 дней — prun")
    }

    func testLastContextUpsertReplacesAndPrunes() {
        let store = QuotaSampleStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t0 = Int64(now.timeIntervalSince1970 * 1000)
        store.upsertLastContext(["uuid-1": LastContextRecord(tokens: 100, t: t0,
                                                             deltaPerTurn: 30)])
        store.upsertLastContext(["uuid-1": LastContextRecord(tokens: 140, t: t0 + 60_000,
                                                             deltaPerTurn: 40),
                                 "uuid-2": LastContextRecord(tokens: 50, t: t0, deltaPerTurn: nil)])
        XCTAssertEqual(store.lastContext["uuid-1"]?.tokens, 140, "свежая порция заменяет")
        XCTAssertEqual(store.lastContext["uuid-2"]?.tokens, 50)
        store.upsertLastContext([:], now: now.addingTimeInterval(15 * 86_400))
        XCTAssertTrue(store.lastContext.isEmpty, "контексты старше 14 дней — prun")
    }

    func testCorruptFileStartsEmpty() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let store = QuotaSampleStore(path: path)
        XCTAssertEqual(store.minuteSeries(now: Date(), minutes: 10), [])
    }

    func testLoadKeepsAllProviderModels() throws {
        // Данные всех провайдеров живут в сторе целиком: claude/gpt нужны
        // аналитике (таблицы, столбцы, журнал); GLM-темпы фильтруются в
        // sessionRates, а не вычищением данных.
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let now = Int64(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 * 1000)
        let file = """
        {"minute":[],"fiveMin":[],
         "buckets":[{"m":\(now),"s":"ext-c","model":"claude-opus-4-7","x":false,"input":100,"output":0,"cacheCreation":0,"cacheRead":0},
                    {"m":\(now),"s":"g","model":"glm-5.3","x":false,"input":50,"output":0,"cacheCreation":0,"cacheRead":0}],
         "offsets":{},"cwds":{},"gaps":[],
         "modelDays":[{"t":\(now - now % 86_400_000),"models":{"claude-opus-4-7":100,"glm-5.3":50}}],
         "sessionLedger":{"ext-c":{"firstSeen":\(now),"lastSeen":\(now),"byModel":{"claude-opus-4-7":100},"external":true,"cwd":"/x"}},
         "hourTotals":[{"t":\(now - now % 3_600_000),"used":150}],
         "factors":{"recentPeak":[],"recentOffPeak":[]}}
        """.data(using: .utf8)!
        try file.write(to: URL(fileURLWithPath: path))
        let store = QuotaSampleStore(path: path)
        XCTAssertEqual(store.buckets.count, 2, "claude-вёдра сохраняются")
        XCTAssertEqual(store.modelDays.first?.models["claude-opus-4-7"], 100)
        XCTAssertEqual(store.sessionLedger["ext-c"]?.byModel["claude-opus-4-7"], 100)
    }

    func testPollGapIsRecordedAndPruned() {
        let store = QuotaSampleStore(path: nil)
        let now = Date(timeIntervalSince1970: 1_800_000)
        store.append(sample(minuteAgo: 20, fiveUsed: 1, now: now))
        store.append(sample(minuteAgo: 18, fiveUsed: 2, now: now))   // 2 мин — не разрыв
        store.append(sample(minuteAgo: 0, fiveUsed: 3, now: now))    // 18 мин — разрыв
        XCTAssertEqual(store.gaps.count, 1, "длинная пауза опроса записана как разрыв")
        XCTAssertEqual(store.gaps.first?.count, 2, "границы [start, end] в ms")
        let weekAgoMs = Int64(now.timeIntervalSince1970 * 1000) - 7 * 24 * 3600_000
        store.append(sample(minuteAgo: -60, fiveUsed: 4, now: now))  // ещё один разрыв
        XCTAssertEqual(store.gaps.count, 2)
        store.append(QuotaSample(t: weekAgoMs - 3600_000, fiveUsed: 0, fiveReset: 0,
                                 weekUsed: 0, weekReset: 0))          // уводит круг за 7д
        XCTAssertTrue(store.gaps.allSatisfy { $0[1] >= weekAgoMs },
                      "разрывы старше 7 дней удаляются вместе с вёдрами")
    }

    func testSaveRotatesPreviousStateToBackup() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let now = Date(timeIntervalSince1970: 1_800_000)
        let store = QuotaSampleStore(path: path)
        store.append(sample(minuteAgo: 1, fiveUsed: 5, now: now))
        try store.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".bak"),
                       "первая запись: прошлого состояния нет — бэкап не создаётся")
        store.append(sample(minuteAgo: 0, fiveUsed: 7, now: now))
        try store.save()
        let bak = try JSONDecoder().decode(ForecastFile.self,
                                           from: Data(contentsOf: URL(fileURLWithPath: path + ".bak")))
        XCTAssertEqual(bak.minute.last?.fiveUsed, 5, "бэкап = состояние до текущей записи")
        XCTAssertEqual(store.minuteSeries(now: now, minutes: 10).map(\.fiveUsed), [5, 7])
    }

    func testCorruptMainRecoversFromBackup() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/usage-samples.json"
        let now = Date(timeIntervalSince1970: 1_800_000)
        let store = QuotaSampleStore(path: path)
        store.append(sample(minuteAgo: 1, fiveUsed: 5, now: now))
        try store.save()
        store.append(sample(minuteAgo: 0, fiveUsed: 7, now: now))
        try store.save()
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let reloaded = QuotaSampleStore(path: path)
        XCTAssertEqual(reloaded.minuteSeries(now: now, minutes: 10).map(\.fiveUsed), [5],
                       "битый главный файл → откат к состоянию бэкапа")
        // Испорченный главный не должен ротироваться поверх хорошего бэкапа.
        try reloaded.save()
        let bak = try JSONDecoder().decode(ForecastFile.self,
                                           from: Data(contentsOf: URL(fileURLWithPath: path + ".bak")))
        XCTAssertEqual(bak.minute.last?.fiveUsed, 5, "бэкап остался хорошим состоянием")
    }
}
