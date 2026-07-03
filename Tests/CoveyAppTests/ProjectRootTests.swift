import XCTest
@testable import covey
import CoveyKit

final class ProjectRootTests: XCTestCase {
    func testProjectRootStripsWorktreesSegment() {
        XCTAssertEqual(projectRoot("/home/u/proj/.worktrees/feat"), "/home/u/proj")
        XCTAssertEqual(projectRoot("/home/u/proj/.worktrees/feat/sub"), "/home/u/proj")
        XCTAssertEqual(projectRoot("/home/u/proj/.worktrees"), "/home/u/proj")
        XCTAssertEqual(projectRoot("/home/u/proj/"), "/home/u/proj")
        XCTAssertEqual(projectRoot("/home/u/proj"), "/home/u/proj")
    }

    func testSessionRootPrefersWorktreeRepo() {
        let wt = Session(name: "w", dir: "/elsewhere/wt", cwd: "/elsewhere/wt",
                         agent: "sh", created: 1, worktreeRepo: "/home/u/proj/")
        XCTAssertEqual(sessionRoot(wt), "/home/u/proj")
        let plain = Session(name: "p", dir: "/home/u/proj/.worktrees/feat",
                            cwd: "/home/u/proj/.worktrees/feat", agent: "sh", created: 1)
        XCTAssertEqual(sessionRoot(plain), "/home/u/proj",
                       "no worktreeRepo: fall back to the path heuristic")
    }

    func testProjectDefaultNameIsLastPathComponent() {
        XCTAssertEqual(projectDefaultName("/home/u/proj"), "proj")
        XCTAssertEqual(projectDefaultName("/home/u/proj/"), "proj")
        XCTAssertEqual(projectDefaultName("/"), "/")
    }

    @MainActor
    func testDisplayNameFallsBackToLastComponent() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        XCTAssertEqual(model.displayName(forDir: "/home/u/proj"), "proj")
    }

    @MainActor
    func testWorktreeSessionGroupsWithRepoRoot() async throws {
        let daemon = try TestDaemon(); defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/repo", agent: "sh",
                                       argv: ["/bin/cat"], name: "root")
        _ = try daemon.registry.create(dir: "/repo/.worktrees/feat", agent: "sh",
                                       argv: ["/bin/cat"], name: "wt",
                                       worktreeRepo: "/repo")
        await model.reconnect()
        _ = await eventually { model.sessions.count == 2 }
        let groups = model.orderedSessions()
        XCTAssertEqual(groups.count, 1, "worktree session must join its repo's project")
        XCTAssertEqual(groups.first?.dir, "/repo")
        XCTAssertEqual(Set(groups.first?.sessions.map(\.name) ?? []), ["root", "wt"])
        daemon.registry.kill(name: "root")
        daemon.registry.kill(name: "wt")
    }
}
