import XCTest
@testable import covey
import CoveyKit

/// Every multi-leaf workspace view is its own nested group above the projects;
/// its leaves leave their own projects and come back on teardown.
@MainActor
final class SidebarGroupsTests: XCTestCase {
    private func session(_ name: String, dir: String) -> Session {
        Session(name: name, dir: dir, cwd: dir, agent: "claude", created: 0)
    }

    private lazy var covey = [session("ui", dir: "/covey"),
                              session("perf", dir: "/covey")]
    private lazy var mentor = [session("ozon", dir: "/mentor"),
                               session("wb", dir: "/mentor")]
    private var projects: [(dir: String, sessions: [Session])] {
        [("/covey", covey), ("/mentor", mentor)]
    }

    private func splitView(_ id: ViewID, _ leaves: [String]) -> WorkspaceView {
        var tree: PaneNode = .agent(session: leaves[0])
        for leaf in leaves.dropFirst() {
            tree = .split(axis: .vertical, ratio: 0.5, first: tree, second: .agent(session: leaf))
        }
        return WorkspaceView(id: id, agentTree: tree, terminal: nil,
                             inspector: .hidden, agentAreaRatio: 1.0)
    }

    private func groups(_ views: [WorkspaceView],
                        _ projects: [(dir: String, sessions: [Session])]? = nil) -> [SidebarGroup] {
        SidebarLayout.groups(projects: projects ?? self.projects, views: views)
    }

    func testNoSplitViewsLeavesTheProjectsUntouched() {
        let g = groups([])
        XCTAssertEqual(g.map(\.id), ["project:/covey", "project:/mentor"])
        XCTAssertEqual(g[0].sessions.map(\.name), ["ui", "perf"])
    }

    func testSplitViewComesFirstAndKeepsTreeOrder() {
        let g = groups([splitView("v1", ["perf", "ui"])])
        XCTAssertEqual(g.first?.id, "splitview:v1")
        XCTAssertEqual(g.first?.kind, .splitView(id: "v1"))
        XCTAssertEqual(g.first?.sessions.map(\.name), ["perf", "ui"])
    }

    func testTwoIndependentSplitViewsEachRenderAsAGroup() {
        let g = groups([splitView("v1", ["ui", "perf"]), splitView("v2", ["ozon", "wb"])])
        XCTAssertEqual(g.map(\.id), ["splitview:v1", "splitview:v2"])
        XCTAssertEqual(g[0].sessions.map(\.name), ["ui", "perf"])
        XCTAssertEqual(g[1].sessions.map(\.name), ["ozon", "wb"])
    }

    func testSplitViewLeavesLeaveTheirOwnProjects() {
        let g = groups([splitView("v1", ["perf", "ozon"])])
        XCTAssertEqual(g.map(\.id), ["splitview:v1", "project:/covey", "project:/mentor"])
        XCTAssertEqual(g[1].sessions.map(\.name), ["ui"])
        XCTAssertEqual(g[2].sessions.map(\.name), ["wb"])
    }

    func testProjectEmptiedByASplitViewDisappears() {
        let g = groups([splitView("v1", ["ozon", "wb"])])
        XCTAssertEqual(g.map(\.id), ["splitview:v1", "project:/covey"])
    }

    func testRegisteredEmptyProjectStaysForItsGhostRow() {
        let g = groups([splitView("v1", ["ui", "perf"])],
                       [("/covey", covey), ("/empty", [])])
        XCTAssertEqual(g.map(\.id), ["splitview:v1", "project:/empty"])
    }

    func testSingleLeafViewsDoNotFormAGroup() {
        let single = WorkspaceView.single("ui", id: "v1")
        XCTAssertEqual(groups([single]).map(\.id), ["project:/covey", "project:/mentor"])
    }

    func testProjectGroupsCarryTheirDirSplitViewsDoNot() {
        let g = groups([splitView("v1", ["ui", "perf"])])
        XCTAssertNil(g[0].dir)
        XCTAssertEqual(g[1].dir, "/mentor")
    }

    func testSplitTitleJoinsLeafNames() {
        XCTAssertEqual(SidebarLayout.splitTitle(leaves: ["a", "b", "c"]), "a+b+c")
    }

    // MARK: - Model-level

    func testModelFeedsViewLeavesIntoTheSplitGroup() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["a", "b", "c"] {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.viewOfSession.count == 3 }
        await model.select("a")
        await model.splitFocusedPane(axis: .vertical, newSession: "b")

        let g = model.sidebarGroups()
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(Set(g[0].sessions.map(\.name)), ["a", "b"])
        XCTAssertEqual(g[1].sessions.map(\.name), ["c"])
    }

    func testKeyboardOrderFollowsTheRenderedSidebar() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["a", "b", "c"] {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.viewOfSession.count == 3 }
        await model.select("b")
        await model.splitFocusedPane(axis: .vertical, newSession: "c")

        let flat = model.sidebarGroups().flatMap { $0.sessions.map(\.name) }
        XCTAssertEqual(model.visibleSessionNames(), flat)
        XCTAssertEqual(model.visibleRows(), flat.map(AppModel.ListRow.session))
    }
}
