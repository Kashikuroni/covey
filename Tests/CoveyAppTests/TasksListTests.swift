import XCTest
import CoveyKit
@testable import covey

final class TasksListTests: XCTestCase {
    private func view(_ id: String, _ lc: PMTaskLifecycle, _ activity: PMActivity,
                      updated: Int64 = 0) -> PMTaskView {
        PMTaskView(task: PMTask(id: id, projectID: "p", title: id, body: "",
                                lifecycle: lc, revision: 1,
                                createdAt: 0, updatedAt: updated),
                   activity: activity, openBindings: [])
    }

    func testGroupingOrderAndLabels() {
        let groups = TasksGrouping.group([
            view("ready-1", .ready, .idle, updated: 1),
            view("run-1", .inProgress, .active, updated: 5),
            view("pause-1", .inProgress, .paused, updated: 3),
            view("done-1", .done, .idle, updated: 9),
        ])
        // Порядок групп: In Progress (active → paused внутри), Ready, Closed;
        // внутри — по updatedAt DESC.
        XCTAssertEqual(groups.map(\.label), ["In Progress", "Ready", "Closed"])
        XCTAssertEqual(groups[0].views.map(\.task.id), ["run-1", "pause-1"])
        XCTAssertEqual(groups[2].views.map(\.task.id), ["done-1"])
    }

    func testEmptyGroupOmitted() {
        let groups = TasksGrouping.group([view("r", .ready, .idle)])
        XCTAssertEqual(groups.map(\.label), ["Ready"])
    }
}
