import XCTest
import CoveyKit
@testable import covey

final class MenuBarForecastGlyphTests: XCTestCase {
    private func forecast(verdict: GLMForecastVerdict, etaMinutes: Double?) -> GLMForecast {
        var f = GLMForecast()
        f.fiveHours = GLMWindowForecast(verdict: verdict, projected: 0, remaining: 0, total: 0,
                                        resetAt: nil, exhaustionAt: etaMinutes.map {
            Int64(Date().timeIntervalSince1970 * 1000 + $0 * 60_000)
        }, headroomPercent: 0, rateCreditsPerHour: 0, agentMinutes: nil)
        return f
    }

    func testOverflowAddsWarningGlyph() {
        let seg = menuBarSegments(usage: nil, codexUsage: nil, glmQuota: nil, glmEnabled: true,
                                  forecast: forecast(verdict: .overflow, etaMinutes: 120))
        let glm = seg.first { $0.label == "GLM" }
        XCTAssertEqual(glm?.value.contains("⚠"), true)
    }

    func testQuietVerdictHasNoGlyph() {
        for v in [GLMForecastVerdict.fits, .underuse, .idle] {
            let seg = menuBarSegments(usage: nil, codexUsage: nil, glmQuota: nil, glmEnabled: true,
                                      forecast: forecast(verdict: v, etaMinutes: nil))
            XCTAssertEqual(seg.first { $0.label == "GLM" }?.value.contains("⚠"), false)
        }
    }

    func testNearExhaustionFitsStillWarns() {
        let seg = menuBarSegments(usage: nil, codexUsage: nil, glmQuota: nil, glmEnabled: true,
                                  forecast: forecast(verdict: .fits, etaMinutes: 30))
        XCTAssertEqual(seg.first { $0.label == "GLM" }?.value.contains("⚠"), true)
    }
}
