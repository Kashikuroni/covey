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

    func testProjectNameUsesPrimaryTextColor() {
        let tk = Tokens.light

        XCTAssertEqual(panelLabelColor(.project, tk: tk), tk.t1)
    }

    func testZoneShortcutNumbersMatchDirectFocusOrder() {
        let expected: [(FocusZone, Int)] = [
            (.session, 1),
            (.agent, 2),
            (.issues, 3),
            (.terminalSplit, 4),
            (.trace, 5),
        ]

        for (zone, number) in expected {
            XCTAssertEqual(zoneShortcutNumber(zone), number, "\(zone)")
        }
    }
}
