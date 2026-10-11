import XCTest
import CoveyKit
@testable import covey

final class TaskEditorModelTests: XCTestCase {
    @MainActor
    func testDirtyTrackingAndSave() async throws {
        var saved: (String, Int?)? = nil
        let m = TaskEditorModel(task: PMTask(id: "t", projectID: "p", title: "T",
                                             body: "старое тело", revision: 3,
                                             createdAt: 0, updatedAt: 0),
                                save: { body, threshold in saved = (body, threshold) })
        XCTAssertFalse(m.isDirty)
        m.body = "новое тело"
        XCTAssertTrue(m.isDirty)
        try await m.saveNow()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(saved?.0, "новое тело")
    }

    func testThresholdRoundTrip() {
        XCTAssertEqual(PMIdleThreshold.parse(PMIdleThreshold.format(1800)), 1800)
        XCTAssertEqual(PMIdleThreshold.parse(PMIdleThreshold.format(259_200)), 259_200)
    }
}
