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

    func testModeSwitchSitsOppositeTheLimitsChip() {
        XCTAssertEqual(windowModeSwitchAlignment(.left), .trailing)
        XCTAssertEqual(windowModeSwitchAlignment(.center), .leading)
        XCTAssertEqual(windowModeSwitchAlignment(.right), .leading)
    }

    func testLimitsOverlayAlignsInsideTopBarContentRegion() {
        XCTAssertEqual(limitsOverlayHorizontalOffset(.left), 78)
        XCTAssertEqual(limitsOverlayHorizontalOffset(.center), 32)
        XCTAssertEqual(limitsOverlayHorizontalOffset(.right), -14)
    }
}
