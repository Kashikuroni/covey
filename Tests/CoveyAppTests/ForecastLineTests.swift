import XCTest
import Foundation
import CoveyKit
@testable import covey

final class ForecastLineTests: XCTestCase {
    private func w(verdict: GLMForecastVerdict, headroom: Double,
                   exhaustionInMinutes: Double? = nil) -> GLMWindowForecast {
        GLMWindowForecast(verdict: verdict, projected: 0, remaining: 0, total: 0, resetAt: nil,
                          exhaustionAt: exhaustionInMinutes.map {
                              Int64(Date().timeIntervalSince1970 * 1000 + $0 * 60_000)
                          }, headroomPercent: headroom, rateCreditsPerHour: 0, agentMinutes: nil)
    }

    func testVerdictsMapToLines() {
        XCTAssertEqual(ForecastText.forecastLine(w(verdict: .fits, headroom: 32), label: "5h", now: Date()), "влезаем, запас 32%")
        XCTAssertEqual(ForecastText.forecastLine(w(verdict: .tight, headroom: 8), label: "5h", now: Date()), "впритык, запас 8%")
        XCTAssertEqual(ForecastText.forecastLine(w(verdict: .calibrating, headroom: 0), label: "5h", now: Date()), "калибровка…")
        XCTAssertTrue(ForecastText.forecastLine(w(verdict: .overflow, headroom: -18, exhaustionInMinutes: 110), label: "5h", now: Date())!.contains("не хватит 18%"))
        XCTAssertTrue(ForecastText.forecastLine(w(verdict: .overflow, headroom: -18, exhaustionInMinutes: 110), label: "5h", now: Date())!.contains("кончится ~"))
        XCTAssertTrue(ForecastText.forecastLine(w(verdict: .underuse, headroom: 40), label: "weekly", now: Date())!.contains("грузить сильнее"))
    }

    func testIdleIsNil() {
        XCTAssertNil(ForecastText.forecastLine(w(verdict: .idle, headroom: 0), label: "5h", now: Date()))
    }

    /// Метки чипа GLM мапятся на окна прогноза: «5h» → fiveHours, «7d» → weekly.
    func testWindowLabelMapsToGLMForecastWindows() {
        var forecast = GLMForecast()
        forecast.fiveHours = w(verdict: .fits, headroom: 10)
        forecast.weekly = w(verdict: .tight, headroom: 5)
        XCTAssertEqual(glmWindowForecast("5h", forecast: forecast)?.verdict, .fits)
        XCTAssertEqual(glmWindowForecast("7d", forecast: forecast)?.verdict, .tight)
        // Чужие метки (Claude/Codex) и нет прогноза — строки нет.
        XCTAssertNil(glmWindowForecast("S 7d", forecast: forecast))
        XCTAssertNil(glmWindowForecast("5h", forecast: nil))
    }
}
