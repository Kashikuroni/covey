import XCTest
@testable import CoveyKit

/// Task 1 (Stage 2): duration живёт сквозь парсер/merge/персистентность,
/// wire-типы прогноза — миллисекундные таймстемпы и устойчивый Codable.
final class CodexForecastTests: XCTestCase {
    func testParserPreservesDurationMinutes() {
        let snapshot = parseCodexRateLimits(["primary": [
            "usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_000,
        ]])
        XCTAssertEqual(snapshot?.primary?.durationMinutes, 300)
        XCTAssertEqual(snapshot?.primary?.label, "5h")
    }

    func testForecastMillisecondTimestampsRoundTrip() throws {
        let forecast = CodexWindowForecast(bucketID: "codex", windowKey: .primary,
            label: "5h", verdict: .fits, usedPercent: 42, projectedPercent: 60,
            projectedP50: nil, projectedP90: nil, headroomPercent: 40,
            resetAt: 1_800_000_000, exhaustionAt: nil, ratePercentPerHour: 3,
            sampleCount: 2, stale: false)
        let decoded = try JSONDecoder().decode(
            CodexWindowForecast.self, from: JSONEncoder().encode(forecast))
        XCTAssertEqual(decoded.resetAt, 1_800_000_000)
        XCTAssertEqual(decoded, forecast)
    }

    func testCodexForecastDecodesWindowsWhenKeyAbsent() throws {
        let data = Data(#"{"updatedAt":123}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexForecast.self, from: data)
        XCTAssertEqual(decoded.windows, [])
        XCTAssertEqual(decoded.updatedAt, 123)
    }

    func testCodexForecastSortsWindowsByBucketThenSlot() {
        func window(_ bucket: String, _ key: CodexForecastWindowKey) -> CodexWindowForecast {
            CodexWindowForecast(bucketID: bucket, windowKey: key, label: "L",
                                verdict: .fits, usedPercent: 1, projectedPercent: 1,
                                projectedP50: nil, projectedP90: nil, headroomPercent: 99,
                                resetAt: nil, exhaustionAt: nil, ratePercentPerHour: 0,
                                sampleCount: 1, stale: false)
        }
        var forecast = CodexForecast(windows: [
            window("zebra", .secondary), window("codex", .secondary),
            window("zebra", .primary), window("codex", .primary),
        ], updatedAt: 1)
        forecast.windows.sort()
        XCTAssertEqual(forecast.windows.map { "\($0.bucketID):\($0.windowKey)" },
                       ["codex:primary", "codex:secondary",
                        "zebra:primary", "zebra:secondary"],
                       "порядок — по bucketID, затем primary перед secondary")
    }

    func testOldPersistedSnapshotDecodesWithoutDuration() throws {
        // До-фичевый JSON: ни durationMinutes, ни codexForecast.
        let legacy = Data(#"{"primaryLabel":"5h","primary":{"utilization":42,"resetUnix":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedCodexUsage.self, from: legacy)
        XCTAssertEqual(decoded.primary?.utilization, 42)
        XCTAssertNil(decoded.primaryDurationMinutes)
        XCTAssertNil(decoded.secondaryDurationMinutes)

        var snapshot = UsageSnapshot()
        snapshot.revision = 3
        let decodedSnapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(decodedSnapshot.codexForecast, "поле отсутствует → nil, декодирование не падает")
    }

    func testPartialMergePreservesDurationLabelAndReset() {
        let base = parseCodexRateLimits(["primary": [
            "usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_000,
        ]])
        // Частичное обновление: только новая утилизация, без duration/reset.
        let partial = parseCodexRateLimits(["primary": ["usedPercent": 55]])
        let merged = mergeCodex(into: base, update: partial!)
        XCTAssertEqual(merged.primary?.window.utilization, 55, "новая утилизация принята")
        XCTAssertEqual(merged.primary?.durationMinutes, 300, "duration базового слота сохранён")
        XCTAssertEqual(merged.primary?.label, "5h")
        XCTAssertEqual(merged.primary?.window.resetUnix, 1_800_000, "reset сохранён")
    }

    func testPartialUpdateKeepsMissingEntireSlot() {
        let base = parseCodexRateLimits([
            "primary": ["usedPercent": 42, "windowDurationMins": 300],
            "secondary": ["usedPercent": 10, "windowDurationMins": 10_080],
        ])
        let partial = parseCodexRateLimits(["primary": ["usedPercent": 55]])
        let merged = mergeCodex(into: base, update: partial!)
        XCTAssertNotNil(merged.secondary, "слот, отсутствующий в апдейте, жив")
        XCTAssertEqual(merged.secondary?.window.utilization, 10)
    }

    func testDurationRoundTripsThroughPersistedUsage() throws {
        let snapshot = parseCodexRateLimits([
            "limitId": "team", "limitName": "Team",
            "primary": ["usedPercent": 42, "windowDurationMins": 300],
            "secondary": ["usedPercent": 4, "windowDurationMins": 10_080],
        ])!
        let persisted = PersistedCodexUsage(snapshot)
        let restored = persisted.live
        XCTAssertEqual(restored.buckets["team"]?.primary?.durationMinutes, 300)
        XCTAssertEqual(restored.buckets["team"]?.secondary?.durationMinutes, 10_080)
    }
}
