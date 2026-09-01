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

    func testPaneSessionNameIsDimmerThanTheZoneLabel() {
        let tk = Tokens.dark

        XCTAssertEqual(panelLabelColor(.paneSession, tk: tk), tk.t3)
        XCTAssertNotEqual(panelLabelColor(.paneSession, tk: tk),
                          panelLabelColor(.zone(active: false), tk: tk))
    }

    /// Имя сессии в заголовке различает agent-панели между собой.
    func testPaneHeaderCarriesTheSessionName() {
        XCTAssertEqual(paneHeaderParts(label: "Agent", name: "ui covey").session,
                       "ui covey")
        XCTAssertEqual(paneHeaderParts(label: "Agent", name: "ui covey").zone, "Agent")
    }

    /// Плейсхолдер (панели ещё нет) показывает только зону.
    func testPaneHeaderWithoutASessionShowsOnlyTheZone() {
        XCTAssertNil(paneHeaderParts(label: "Agent", name: "").session)
    }

    func testProjectNameUsesPrimaryTextColor() {
        let tk = Tokens.light

        XCTAssertEqual(panelLabelColor(.project, tk: tk), tk.t1)
    }
}
