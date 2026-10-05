import XCTest
import Foundation
import CoveyKit
@testable import CoveydCore

final class ForecastEngineProjectionTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T11:00:00Z")!  // пт 11:00 UTC, офф-пик; пик 06:00–10:00 UTC уже прошёл


    private func window(used: Double, total: Double, hoursToReset: Double, from anchor: Date? = nil) -> GLMLimitWindow {
        // Якорь: resetAt должен жить в том же «now», что и проекция (t0 по умолчанию).
        let base = anchor ?? t0
        return GLMLimitWindow(total: total, used: used, remaining: total - used,
                              usedPercent: used / total * 100, remainingPercent: 100 - used / total * 100,
                              resetAt: Int64((base + hoursToReset * 3600).timeIntervalSince1970 * 1000))
    }

    private func bothFactors() -> CalibrationFactors {
        var f = CalibrationFactors()
        f.peak = 0.05; f.peakAt = t0
        f.offPeak = 0.025; f.offPeakAt = t0
        return f
    }

    func testOverflowWhenProjectedExceedsRemaining() {
        // 12к токенов/ч × 0.025 (офф) = 300 кр/ч; 2ч до сброса → +600; remaining 500.
        let w = window(used: 500, total: 1000, hoursToReset: 2)
        let f = ForecastEngine.project(used: w.used, total: w.total, remaining: w.remaining,
                                       resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                       tokensPerHour: 12_000, flatCreditsPerHour: 300,
                                       factors: bothFactors(), now: t0,
                                       marginPercent: 15, underusePercent: 30)
        XCTAssertEqual(f.verdict, .overflow)
        XCTAssertEqual(f.projected, 1100, accuracy: 1)
        XCTAssertLessThan(f.headroomPercent, 0)
        XCTAssertNotNil(f.exhaustionAt)
    }

    func testProjectionBendsAcrossPeakBoundary() {
        // t0 = пт 11:00 UTC. До пика (06:00 UTC след. недели) далеко; сместим t0:
        // возьмём чт 15:30 UTC+8 = 07:30 UTC (пик). До 10:00 UTC пик (2.5ч), потом офф.
        let thursday = ISO8601DateFormatter().date(from: "2026-10-01T07:30:00Z")!
        let w = window(used: 0, total: 10_000, hoursToReset: 8, from: thursday)   // reset 15:30 UTC
        let f = ForecastEngine.project(used: 0, total: 10_000, remaining: 10_000,
                                       resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                       tokensPerHour: 20_000, flatCreditsPerHour: 0,
                                       factors: bothFactors(), now: thursday,
                                       marginPercent: 15, underusePercent: 30)
        // Пик 2.5ч × 20000 × 0.05 = 2500; офф 5.5ч × 20000 × 0.025 = 2750 → 5250.
        XCTAssertEqual(f.projected, 5250, accuracy: 2, "плоская ставка дала бы 10000×0.05 или ×0.025 — вдвое мимо")
        XCTAssertEqual(f.verdict, .underuse)
    }

    func testTightWhenHeadroomBelowMargin() {
        // projected = 900, remaining = 950, total = 1000: запас 50 < 15% total.
        let w = window(used: 50, total: 1000, hoursToReset: 1)
        let f = ForecastEngine.project(used: w.used, total: w.total, remaining: w.remaining,
                                       resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                       tokensPerHour: 34_000, flatCreditsPerHour: 850,
                                       factors: bothFactors(), now: t0,
                                       marginPercent: 15, underusePercent: 30)
        XCTAssertEqual(f.verdict, .tight)
    }

    func testIdleWhenNoRate() {
        let w = window(used: 100, total: 1000, hoursToReset: 1)
        let f = ForecastEngine.project(used: w.used, total: w.total, remaining: w.remaining,
                                       resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                       tokensPerHour: 0, flatCreditsPerHour: 0,
                                       factors: bothFactors(), now: t0,
                                       marginPercent: 15, underusePercent: 30)
        XCTAssertEqual(f.verdict, .idle)
        XCTAssertNil(f.exhaustionAt)
        XCTAssertNil(f.agentMinutes)
    }

    func testFitsAndUnderuseBoundaries() {
        func verdict(projected used: Double, remaining: Double) -> GLMForecastVerdict {
            let w = window(used: used, total: 1000, hoursToReset: 1)
            return ForecastEngine.project(used: used, total: 1000, remaining: remaining,
                                          resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                          tokensPerHour: 0, flatCreditsPerHour: 0.001,
                                          factors: bothFactors(), now: t0,
                                          marginPercent: 15, underusePercent: 30).verdict
        }
        // Запас = remaining − projected (projected ≈ used при мизерной ставке).
        // Границы относительно total=1000: > 300 → underuse; < 150 → tight; иначе fits.
        // projected 100: remaining 350 → запас 250 → fits.
        XCTAssertEqual(verdict(projected: 100, remaining: 350), .fits)
        // remaining 950 → запас 850 > 300 → underuse.
        XCTAssertEqual(verdict(projected: 100, remaining: 950), .underuse)
        // remaining 400 → запас ровно 300, НЕ больше порога → fits.
        XCTAssertEqual(verdict(projected: 100, remaining: 400), .fits)
        // remaining 401 → запас 301 > 300 → underuse.
        XCTAssertEqual(verdict(projected: 100, remaining: 401), .underuse)
    }

    func testAgentBudgetMinutes() {
        let w = window(used: 0, total: 1000, hoursToReset: 2)
        let f = ForecastEngine.project(used: 0, total: 1000, remaining: 1000,
                                       resetAt: Date(timeIntervalSince1970: Double(w.resetAt) / 1000),
                                       tokensPerHour: 12_000, flatCreditsPerHour: 300,
                                       factors: bothFactors(), now: t0,
                                       marginPercent: 15, underusePercent: 30)
        XCTAssertEqual(f.agentMinutes ?? 0, 200, accuracy: 1, "1000 кр / 300 кр/ч = 3.33ч = 200 мин")
    }
}
