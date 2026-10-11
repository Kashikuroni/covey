import XCTest
import CoveyKit
@testable import covey

final class TasksDrawerTests: XCTestCase {
    func testTasksForSelectedSessionProject() {
        let inProject = PMTaskView(task: PMTask(id: "a", projectID: "p1", title: "A",
                                                body: "", revision: 1, createdAt: 0, updatedAt: 0),
                                   activity: .active, openBindings: [])
        let other = PMTaskView(task: PMTask(id: "b", projectID: "p2", title: "B",
                                            body: "", revision: 1, createdAt: 0, updatedAt: 0),
                               activity: .idle, openBindings: [])
        let got = TasksDrawer.tasks(views: [inProject, other], projectID: "p1")
        XCTAssertEqual(got.map(\.task.id), ["a"])
        XCTAssertEqual(TasksDrawer.tasks(views: [inProject, other], projectID: nil), [])
    }
}
