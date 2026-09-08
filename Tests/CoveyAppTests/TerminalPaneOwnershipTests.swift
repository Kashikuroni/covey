import XCTest
@testable import covey

final class TerminalPaneOwnershipTests: XCTestCase {
    func testNewMountSupersedesOldLeaseForSameSession() {
        var ownership = TerminalPaneOwnership()
        let old = ownership.mount(session: "agent")
        let current = ownership.mount(session: "agent")

        XCTAssertFalse(ownership.isCurrent(old))
        XCTAssertTrue(ownership.isCurrent(current))
    }

    func testDifferentSessionsRemainIndependentlyCurrent() {
        var ownership = TerminalPaneOwnership()
        let first = ownership.mount(session: "agent-a")
        let second = ownership.mount(session: "agent-b")

        XCTAssertTrue(ownership.isCurrent(first))
        XCTAssertTrue(ownership.isCurrent(second))
    }

    func testStaleUnmountDoesNotRevokeNewLease() {
        var ownership = TerminalPaneOwnership()
        let old = ownership.mount(session: "agent")
        let current = ownership.mount(session: "agent")

        ownership.unmount(old)

        XCTAssertTrue(ownership.isCurrent(current))
    }

    func testCurrentUnmountRevokesLease() {
        var ownership = TerminalPaneOwnership()
        let current = ownership.mount(session: "agent")

        ownership.unmount(current)

        XCTAssertFalse(ownership.isCurrent(current))
    }

    func testStaleTwoColumnResizeCannotFollowCurrentFullResize() {
        var ownership = TerminalPaneOwnership()
        let old = ownership.mount(session: "agent")
        let current = ownership.mount(session: "agent")
        var delivered = [[Int]]()

        if ownership.isCurrent(current) {
            delivered.append([100, 40])
        }
        if ownership.isCurrent(old) {
            delivered.append([2, 40])
        }

        XCTAssertEqual(delivered, [[100, 40]])
    }

    func testCurrentTwoColumnResizeRemainsAccepted() {
        var ownership = TerminalPaneOwnership()
        let current = ownership.mount(session: "agent")
        var delivered = [[Int]]()

        if ownership.isCurrent(current) {
            delivered.append([2, 40])
        }

        XCTAssertEqual(delivered, [[2, 40]])
    }

    func testReusedSessionNameGetsDifferentLease() {
        var ownership = TerminalPaneOwnership()
        let first = ownership.mount(session: "agent")
        ownership.unmount(first)
        let reused = ownership.mount(session: "agent")

        XCTAssertNotEqual(first, reused)
        XCTAssertFalse(ownership.isCurrent(first))
        XCTAssertTrue(ownership.isCurrent(reused))
    }

    // MARK: - Передача владения

    /// Переходное двойное монтирование: SwiftUI строит вторую панель той же
    /// сессии и сносит её. Живая панель обязана получить сессию обратно —
    /// иначе её вывод и её resize глушатся до следующего remount.
    func testUnmountingTheOwnerPassesTheSessionToTheSurvivingPane() {
        var ownership = TerminalPaneOwnership()
        let survivor = ownership.mount(session: "agent")
        let doomed = ownership.mount(session: "agent")

        XCTAssertEqual(ownership.unmount(doomed), .passed(survivor))
        XCTAssertTrue(ownership.isCurrent(survivor))
    }

    func testUnmountingANonOwnerMovesNothing() {
        var ownership = TerminalPaneOwnership()
        let old = ownership.mount(session: "agent")
        let owner = ownership.mount(session: "agent")

        XCTAssertEqual(ownership.unmount(old), TerminalPaneOwnership.Handover.none)
        XCTAssertTrue(ownership.isCurrent(owner))
    }

    func testUnmountingTheLastPaneLeavesTheSessionVacant() {
        var ownership = TerminalPaneOwnership()
        let only = ownership.mount(session: "agent")

        XCTAssertEqual(ownership.unmount(only), .vacant)
        XCTAssertFalse(ownership.isCurrent(only))
    }

    /// Владение передаётся по цепочке: сносят по одной, сессия каждый раз
    /// достаётся последней оставшейся.
    func testOwnershipWalksBackThroughEveryRemainingPane() {
        var ownership = TerminalPaneOwnership()
        let first = ownership.mount(session: "agent")
        let second = ownership.mount(session: "agent")
        let third = ownership.mount(session: "agent")

        XCTAssertEqual(ownership.unmount(third), .passed(second))
        XCTAssertEqual(ownership.unmount(second), .passed(first))
        XCTAssertEqual(ownership.unmount(first), .vacant)
    }

    func testUnmountingAnUnknownLeaseIsANoop() {
        var ownership = TerminalPaneOwnership()
        let owner = ownership.mount(session: "agent")
        let other = ownership.mount(session: "agent-b")
        ownership.unmount(other)

        XCTAssertEqual(ownership.unmount(other), TerminalPaneOwnership.Handover.none)
        XCTAssertTrue(ownership.isCurrent(owner))
    }
}
