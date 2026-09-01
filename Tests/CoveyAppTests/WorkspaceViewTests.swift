import XCTest
@testable import covey
import CoveyKit

@MainActor final class WorkspaceViewTests: XCTestCase {
    func testSingleViewHasOneLeafAndIsNotSplit() {
        let v = WorkspaceView.single("a", id: "v1")
        XCTAssertEqual(v.leaves, ["a"])
        XCTAssertFalse(v.isSplit)
        XCTAssertEqual(v.inspector, .hidden)
        XCTAssertNil(v.terminal)
    }

    func testRemoveLeafFromSplitReturnsSuccessorAndKeepsView() {
        var v = WorkspaceView.single("a", id: "v1")
        v.agentTree = .split(axis: .vertical, ratio: 0.5,
                             first: .agent(session: "a"), second: .agent(session: "b"))
        let r = v.removeLeaf("a")
        XCTAssertEqual(r.successor, "b")
        XCTAssertFalse(r.emptied)
        XCTAssertEqual(v.leaves, ["b"])
        XCTAssertFalse(v.isSplit)
    }

    func testRemoveLastLeafEmptiesView() {
        var v = WorkspaceView.single("a", id: "v1")
        let r = v.removeLeaf("a")
        XCTAssertTrue(r.emptied)
    }

    func testRemoveAbsentLeafIsNoOp() {
        var v = WorkspaceView.single("a", id: "v1")
        let r = v.removeLeaf("z")
        XCTAssertNil(r.successor)
        XCTAssertFalse(r.emptied)
        XCTAssertEqual(v.leaves, ["a"])
    }

    func testRenameLeafRewritesTree() {
        var v = WorkspaceView.single("a", id: "v1")
        v.renameLeaf("a", to: "a2")
        XCTAssertEqual(v.leaves, ["a2"])
    }

    func testWorkspaceViewPersistRoundTrip() {
        var v = WorkspaceView.single("a", id: "v1")
        v.agentTree = .split(axis: .horizontal, ratio: 0.4,
                             first: .agent(session: "a"), second: .agent(session: "b"))
        v.terminal = TerminalZone(shellSession: "s-9")
        v.inspector = .shown(mode: .trace)
        v.agentAreaRatio = 0.55
        XCTAssertEqual(WorkspaceView(persisted: v.persisted), v)
    }

    func testTerminalOpenWithoutShellRoundTrips() {
        var v = WorkspaceView.single("a", id: "v1")
        v.terminal = TerminalZone(shellSession: nil)   // open, awaiting relink
        let back = WorkspaceView(persisted: v.persisted)
        XCTAssertNotNil(back.terminal)
        XCTAssertNil(back.terminal?.shellSession)
    }

    func testHiddenInspectorRoundTrips() {
        let v = WorkspaceView.single("a", id: "v1")
        XCTAssertEqual(WorkspaceView(persisted: v.persisted).inspector, .hidden)
    }
}
