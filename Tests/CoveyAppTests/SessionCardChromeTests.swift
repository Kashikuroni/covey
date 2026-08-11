import XCTest
@testable import covey

final class SessionCardChromeTests: XCTestCase {
    func testFocusBorderFadesAcrossFirstQuarter() {
        XCTAssertEqual(SessionCardChrome.focusFadeWidth(cardWidth: 320), 80,
                       accuracy: 0.001)
    }

    func testFocusBorderFadeNeverUsesNegativeWidth() {
        XCTAssertEqual(SessionCardChrome.focusFadeWidth(cardWidth: -20), 0,
                       accuracy: 0.001)
    }
}
