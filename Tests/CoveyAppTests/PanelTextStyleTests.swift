import SwiftUI
import XCTest
@testable import covey

final class PanelTextStyleTests: XCTestCase {
    func testInactivePanelCaptionUsesPrimaryTextColor() {
        let tk = Tokens.dark

        XCTAssertEqual(panelLabelColor(.zone(active: false), tk: tk), tk.t1)
    }

    func testActivePanelCaptionKeepsAccentColor() {
        let tk = Tokens.dark

        XCTAssertEqual(panelLabelColor(.zone(active: true), tk: tk), tk.accent)
    }
}
