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
                                save: { body, threshold, _ in
                                    saved = (body, threshold)
                                    return 4
                                })
        XCTAssertFalse(m.isDirty)
        m.body = "новое тело"
        XCTAssertTrue(m.isDirty)
        try await m.saveNow()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(saved?.0, "новое тело")
    }

    /// Review finding 2: ревизия обновляется после каждого успешного сохранения —
    /// второй autosave обязан проходить с НОВОЙ ревизией, а не протухшей.
    @MainActor
    func testSecondSaveUsesFreshRevision() async throws {
        var seenRevisions: [Int64] = []
        var rev: Int64 = 3
        let m = TaskEditorModel(task: PMTask(id: "t", projectID: "p", title: "T",
                                             body: "v1", revision: 3,
                                             createdAt: 0, updatedAt: 0),
                                save: { _, _, expected in
                                    seenRevisions.append(expected)
                                    rev += 1
                                    return rev
                                })
        m.body = "v2"
        try await m.saveNow()
        m.body = "v3"
        try await m.saveNow()
        XCTAssertEqual(seenRevisions, [3, 4], "вторая сохранялка идёт с ревизией из ответа демона")
    }

    @MainActor
    func testSaveFailureSurfacesErrorAndKeepsDirty() async throws {
        struct Boom: Error {}
        let m = TaskEditorModel(task: PMTask(id: "t", projectID: "p", title: "T",
                                             body: "v1", revision: 3,
                                             createdAt: 0, updatedAt: 0),
                                save: { _, _, _ in throw Boom() })
        m.body = "v2"
        do { try await m.saveNow(); XCTFail("expected throw") }
        catch {}
        XCTAssertNotNil(m.lastError)
        XCTAssertTrue(m.isDirty)
    }

    func testThresholdRoundTrip() {
        XCTAssertEqual(PMIdleThreshold.parse(PMIdleThreshold.format(1800)), 1800)
        XCTAssertEqual(PMIdleThreshold.parse(PMIdleThreshold.format(259_200)), 259_200)
    }
}
