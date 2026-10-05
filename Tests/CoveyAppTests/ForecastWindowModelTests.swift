import XCTest
import Foundation
import CoveyKit
@testable import covey

final class ForecastWindowModelTests: XCTestCase {
    func testFactorDescription() {
        XCTAssertEqual(ForecastWindow.factorDescription(0.05, calibratedAt: nil, now: Date()),
                       "0.05000")
        let ago = Date().addingTimeInterval(-3 * 3600)
        XCTAssertTrue(ForecastWindow.factorDescription(0.05, calibratedAt: ago, now: Date())
            .contains("3ч назад"))
        XCTAssertEqual(ForecastWindow.factorDescription(nil, calibratedAt: nil, now: Date()),
                       "калибровка…")
    }

    func testAgentRowSuffixes() {
        XCTAssertEqual(ForecastWindow.agentSuffix(external: false, sidechainShare: 0.2), "")
        XCTAssertEqual(ForecastWindow.agentSuffix(external: true, sidechainShare: 0.2), " · внешняя")
        XCTAssertEqual(ForecastWindow.agentSuffix(external: true, sidechainShare: 0.8), " · внешняя · субагенты")
        XCTAssertEqual(ForecastWindow.agentSuffix(external: false, sidechainShare: 0.8), " · субагенты")
    }

    func testRegimeHeaderUsesLocalTime() {
        let flip = Date().addingTimeInterval(2 * 3600 + 40 * 60)
        let header = ForecastWindow.regimeHeader(peakNow: true, nextFlipAt: flip, now: Date())
        XCTAssertTrue(header.contains("пик"), header)
        XCTAssertTrue(header.contains("2ч40м"), header)
    }
}
