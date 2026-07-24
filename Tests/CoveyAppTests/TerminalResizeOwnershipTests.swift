import XCTest
@testable import covey

final class TerminalResizeOwnershipTests: XCTestCase {
    func testNewMountSupersedesOldLeaseForSameSession() {
        var ownership = TerminalResizeOwnership()
        let old = ownership.mount(session: "agent")
        let current = ownership.mount(session: "agent")

        XCTAssertFalse(ownership.isCurrent(old))
        XCTAssertTrue(ownership.isCurrent(current))
    }

    func testDifferentSessionsRemainIndependentlyCurrent() {
        var ownership = TerminalResizeOwnership()
        let first = ownership.mount(session: "agent-a")
        let second = ownership.mount(session: "agent-b")

        XCTAssertTrue(ownership.isCurrent(first))
        XCTAssertTrue(ownership.isCurrent(second))
    }

    func testStaleUnmountDoesNotRevokeNewLease() {
        var ownership = TerminalResizeOwnership()
        let old = ownership.mount(session: "agent")
        let current = ownership.mount(session: "agent")

        ownership.unmount(old)

        XCTAssertTrue(ownership.isCurrent(current))
    }

    func testCurrentUnmountRevokesLease() {
        var ownership = TerminalResizeOwnership()
        let current = ownership.mount(session: "agent")

        ownership.unmount(current)

        XCTAssertFalse(ownership.isCurrent(current))
    }

    func testStaleTwoColumnResizeCannotFollowCurrentFullResize() {
        var ownership = TerminalResizeOwnership()
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
        var ownership = TerminalResizeOwnership()
        let current = ownership.mount(session: "agent")
        var delivered = [[Int]]()

        if ownership.isCurrent(current) {
            delivered.append([2, 40])
        }

        XCTAssertEqual(delivered, [[2, 40]])
    }

    func testReusedSessionNameGetsDifferentLease() {
        var ownership = TerminalResizeOwnership()
        let first = ownership.mount(session: "agent")
        ownership.unmount(first)
        let reused = ownership.mount(session: "agent")

        XCTAssertNotEqual(first, reused)
        XCTAssertFalse(ownership.isCurrent(first))
        XCTAssertTrue(ownership.isCurrent(reused))
    }
}
