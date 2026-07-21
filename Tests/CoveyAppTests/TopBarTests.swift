import SwiftUI
import XCTest
@testable import covey

final class TopBarTests: XCTestCase {
    func testUsagePlacementMapsToTopBarAlignment() {
        XCTAssertEqual(topBarAlignment(.left), .leading)
        XCTAssertEqual(topBarAlignment(.center), .center)
        XCTAssertEqual(topBarAlignment(.right), .trailing)
    }
}
