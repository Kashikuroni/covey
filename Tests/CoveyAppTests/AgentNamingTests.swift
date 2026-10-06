import XCTest
import Foundation
@testable import covey

/// Имя агента-пути → проект как в списке сессий: корень (без .worktrees),
/// имя — пользовательский rename или последний компонент; ветка — хвост
/// после .worktrees/. Имена Covey-сессий и фолбэки не трогаем.
final class AgentNamingTests: XCTestCase {
    private let home = "/Users/x"

    private func parts(_ raw: String, renames: [String: String] = [:]) -> (project: String, branch: String?)? {
        AgentNaming.projectParts(raw: raw, home: home) { renames[$0] ?? projectDefaultName($0) }
    }

    func testWorktreePathYieldsProjectNameAndBranch() {
        let p = parts("~/code/ms/.worktrees/perf/ozon_unit")
        XCTAssertEqual(p?.project, "ms")
        XCTAssertEqual(p?.branch, "perf/ozon_unit")
    }

    func testUserRenameWinsOverDefaultName() {
        let p = parts("~/code/ms/.worktrees/perf/ozon_unit", renames: ["/Users/x/code/ms": "Mentor"])
        XCTAssertEqual(p?.project, "Mentor")
    }

    func testPlainPathYieldsProjectWithoutBranch() {
        let p = parts("~/code/ms")
        XCTAssertEqual(p?.project, "ms")
        XCTAssertNil(p?.branch)
    }

    func testAbsolutePathOutsideHomeWorks() {
        let p = parts("/Volumes/work/ms/.worktrees/fix")
        XCTAssertEqual(p?.project, "ms")
        XCTAssertEqual(p?.branch, "fix")
    }

    func testSessionNameIsNotAPath() {
        XCTAssertNil(parts("fix-auth"))
        XCTAssertNil(parts("ext:-Users-x-proj"), "фолбэк-слаг — не путь, именование не применяется")
    }
}
