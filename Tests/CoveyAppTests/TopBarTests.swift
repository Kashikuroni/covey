import SwiftUI
import XCTest
@testable import covey

final class TopBarTests: XCTestCase {
    func testUsageAndClockShareThirteenPointMonospacedTypography() {
        XCTAssertEqual(topBarFontSize, 13)
        XCTAssertEqual(topBarFontDesign, .monospaced)
    }

    func testUsagePlacementMapsToTopBarAlignment() {
        XCTAssertEqual(topBarAlignment(.left), .leading)
        XCTAssertEqual(topBarAlignment(.center), .center)
        XCTAssertEqual(topBarAlignment(.right), .trailing)
    }

    func testUsagePlacementMapsToTopOverlayAlignment() {
        XCTAssertEqual(topOverlayAlignment(.left), .topLeading)
        XCTAssertEqual(topOverlayAlignment(.center), .top)
        XCTAssertEqual(topOverlayAlignment(.right), .topTrailing)
    }
}
