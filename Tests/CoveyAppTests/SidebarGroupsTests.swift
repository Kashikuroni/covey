import XCTest
@testable import covey
import CoveyKit

/// Split View — псевдо-проект сверху списка: сессии сплита уходят из своих
/// проектов в отдельную группу и возвращаются на своё место, когда сплит
/// разобран.
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

    func testNoSplitLeavesTheProjectsUntouched() {
        let groups = SidebarLayout.groups(projects: projects, splitLeaves: [])
        XCTAssertEqual(groups.map(\.id), ["project:/covey", "project:/mentor"])
        XCTAssertEqual(groups[0].sessions.map(\.name), ["ui", "perf"])
    }

    func testSplitGroupComesFirstAndKeepsTreeOrder() {
        // Порядок обхода дерева, а не сайдбара: perf раньше ui.
        let groups = SidebarLayout.groups(projects: projects,
                                          splitLeaves: ["perf", "ui"])
        XCTAssertEqual(groups.first?.id, "splitview")
        XCTAssertEqual(groups.first?.kind, .splitView)
        XCTAssertEqual(groups.first?.sessions.map(\.name), ["perf", "ui"])
    }

    func testSplitSessionsLeaveTheirOwnProjects() {
        let groups = SidebarLayout.groups(projects: projects,
                                          splitLeaves: ["perf", "ozon"])
        XCTAssertEqual(groups.map(\.id),
                       ["splitview", "project:/covey", "project:/mentor"])
        XCTAssertEqual(groups[1].sessions.map(\.name), ["ui"])
        XCTAssertEqual(groups[2].sessions.map(\.name), ["wb"])
    }

    func testSplitMayMixProjects() {
        let groups = SidebarLayout.groups(projects: projects,
                                          splitLeaves: ["ui", "ozon"])
        XCTAssertEqual(groups.first?.sessions.map(\.name), ["ui", "ozon"])
    }

    func testProjectEmptiedByTheSplitDisappears() {
        let groups = SidebarLayout.groups(projects: projects,
                                          splitLeaves: ["ozon", "wb"])
        XCTAssertEqual(groups.map(\.id), ["splitview", "project:/covey"],
                       "проект, чьи сессии целиком в сплите, не показывается")
    }

    func testRegisteredEmptyProjectStaysForItsGhostRow() {
        let groups = SidebarLayout.groups(
            projects: [("/covey", covey), ("/empty", [])],
            splitLeaves: ["ui", "perf"])
        XCTAssertEqual(groups.map(\.id), ["splitview", "project:/empty"],
                       "пустой зарегистрированный проект остаётся ради ghost-строки")
    }

    func testUnknownLeafIsIgnored() {
        // Лист мёртвой сессии не должен рисовать пустую карточку.
        let groups = SidebarLayout.groups(projects: projects,
                                          splitLeaves: ["ui", "ghost"])
        XCTAssertEqual(groups.first?.sessions.map(\.name), ["ui"])
    }

    func testModelFeedsTheTreeLeavesIntoTheSplitGroup() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["a", "b", "c"] {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 3 }
        await model.select("a")
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .session("b"), label: "b"))
        _ = await eventually { model.splitTree?.leafCount == 2 }

        let groups = model.sidebarGroups()
        XCTAssertEqual(groups.map(\.id), ["splitview", "project:/tmp"])
        XCTAssertEqual(groups[0].sessions.map(\.name), ["a", "b"])
        XCTAssertEqual(groups[1].sessions.map(\.name), ["c"])
    }

    /// j/k и ⌘1…9 обязаны идти в том же порядке, в каком список нарисован,
    /// иначе навигация выбирает не ту карточку, что подсвечена.
    func testKeyboardOrderFollowsTheRenderedSidebar() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        for name in ["a", "b", "c"] {
            _ = try daemon.registry.create(dir: "/tmp", agent: "claude",
                                           argv: ["/bin/cat"], name: name)
        }
        _ = await eventually { model.sessions.count == 3 }
        await model.select("b")
        model.perform(.splitTerminalVertically)
        await model.splitPickerChosen(.init(kind: .session("c"), label: "c"))
        _ = await eventually { model.splitTree?.leafCount == 2 }

        XCTAssertEqual(model.sidebarGroups().flatMap { $0.sessions.map(\.name) },
                       ["b", "c", "a"], "предусловие: Split View сверху")
        XCTAssertEqual(model.visibleSessionNames(), ["b", "c", "a"])
        XCTAssertEqual(model.visibleRows(), [.session("b"), .session("c"), .session("a")])
    }

    func testProjectGroupsCarryTheirDirForReorderAndGhostRows() {
        let groups = SidebarLayout.groups(projects: projects, splitLeaves: ["ui"])
        XCTAssertNil(groups[0].dir, "у Split View нет каталога — драг и ghost не его")
        XCTAssertEqual(groups[1].dir, "/covey")
    }
}
