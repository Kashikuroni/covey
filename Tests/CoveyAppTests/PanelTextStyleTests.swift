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

    /// Вторая строка заголовка — основным цветом, как неактивная зона.
    func testPaneSubjectUsesPrimaryTextColor() {
        let tk = Tokens.dark

        XCTAssertEqual(panelLabelColor(.paneSubject, tk: tk), tk.t1)
        XCTAssertEqual(panelLabelColor(.paneSubject, tk: tk),
                       panelLabelColor(.zone(active: false), tk: tk))
    }

    /// Имени сессии мало: в сплите рядом стоят сессии разных проектов.
    func testPaneSubjectCarriesTheProjectAndTheSession() {
        XCTAssertEqual(
            paneHeaderSubject(project: "covey", session: "ui covey", isShell: false),
            "covey - ui covey")
    }

    /// Шелл-колонка: её сессия служебная, в строке остаётся проект.
    func testShellPaneSubjectIsTheProjectAlone() {
        XCTAssertEqual(
            paneHeaderSubject(project: "covey", session: "ui covey+sh", isShell: true),
            "covey")
    }

    /// Проект ещё не известен (сессии нет в списке) — остаётся имя сессии,
    /// чтобы строка не пропала и заголовки панелей не разъехались по высоте.
    func testPaneSubjectFallsBackToTheSessionNameWithoutAProject() {
        XCTAssertEqual(paneHeaderSubject(project: nil, session: "ui covey", isShell: false),
                       "ui covey")
        XCTAssertEqual(paneHeaderSubject(project: "", session: "ui covey", isShell: true),
                       "ui covey")
    }

    /// Плейсхолдер (панели ещё нет) показывает только зону.
    func testPaneHeaderWithoutASessionShowsOnlyTheZone() {
        XCTAssertNil(paneHeaderSubject(project: "covey", session: "", isShell: false))
    }

    func testProjectNameUsesPrimaryTextColor() {
        let tk = Tokens.light

        XCTAssertEqual(panelLabelColor(.project, tk: tk), tk.t1)
    }
}
