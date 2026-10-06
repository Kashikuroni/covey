import SwiftUI
import XCTest
@testable import covey

final class TopBarTests: XCTestCase {
    func testUsageAndClockShareThirteenPointMonospacedTypography() {
        XCTAssertEqual(topBarFontSize, 13)
        XCTAssertEqual(topBarFontDesign, .monospaced)
    }

    func testUsagePlacementMapsToTopBarAlignment() {
        // Placement больше не двигает чип: лимиты всегда по центру.
        XCTAssertEqual(topBarAlignment(.left), .center)
        XCTAssertEqual(topBarAlignment(.center), .center)
        XCTAssertEqual(topBarAlignment(.right), .center)
    }

    func testUsagePlacementMapsToTopOverlayAlignment() {
        XCTAssertEqual(topOverlayAlignment(.left), .topLeading)
        XCTAssertEqual(topOverlayAlignment(.center), .top)
        XCTAssertEqual(topOverlayAlignment(.right), .topTrailing)
    }

    func testModeSwitchPinnedLeftAndLimitsCentered() {
        // Позиция зафиксирована: свитч слева, лимиты/часы всегда по центру.
        XCTAssertEqual(windowModeSwitchAlignment(.left), .leading)
        XCTAssertEqual(windowModeSwitchAlignment(.center), .leading)
        XCTAssertEqual(windowModeSwitchAlignment(.right), .leading)
        XCTAssertEqual(topBarAlignment(.left), .center)
        XCTAssertEqual(topBarAlignment(.center), .center)
        XCTAssertEqual(topBarAlignment(.right), .center)
    }

    func testLimitsOverlayAlignsInsideTopBarContentRegion() {
        XCTAssertEqual(limitsOverlayHorizontalOffset(.left), 32)
        XCTAssertEqual(limitsOverlayHorizontalOffset(.center), 32)
        XCTAssertEqual(limitsOverlayHorizontalOffset(.right), 32)
    }
}
