import XCTest
import CoveyKit

final class CoveyConfigForecastTests: XCTestCase {
    func testForecastSectionDecodesOptionally() throws {
        let json = #"{"glmForecast":{"includeExternal":false,"marginPercent":25}}"#
        let cfg = try JSONDecoder().decode(CoveyConfig.self, from: Data(json.utf8))
        let f = cfg.glmForecast
        XCTAssertEqual(f?.includeExternal, false)
        XCTAssertEqual(f?.marginPercent, 25)
        XCTAssertNil(f?.imminentMinutes)
        XCTAssertNil(CoveyConfig().glmForecast)
    }
}
