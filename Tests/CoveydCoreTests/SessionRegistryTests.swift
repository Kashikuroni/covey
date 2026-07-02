import XCTest
@testable import CoveydCore
import CoveyKit

final class SessionRegistryTests: XCTestCase {
    func testCreateAssignsNameAndClock() throws {
        let reg = SessionRegistry(clock: { 1234 })
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        XCTAssertFalse(s.name.isEmpty)
        XCTAssertEqual(s.created, 1234)
        XCTAssertEqual(reg.list().map(\.name), [s.name])
        reg.kill(name: s.name)
    }
    
    func testDuplicateNameThrows() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "dup")
        XCTAssertThrowsError(
            try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "dup")
        ) { error in
            XCTAssertEqual(error as? RegistryError, .duplicateName("dup"))
        }
        reg.kill(name: "dup")
    }
    
    func testKillRemovesFromList() throws {
        let reg = SessionRegistry()
        let exitExp = expectation(description: "exit")
        reg.onExit = { _, _ in exitExp.fulfill() }
        let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        reg.kill(name: s.name)
        wait(for: [exitExp], timeout: 5)
        XCTAssertTrue(reg.list().isEmpty)
    }
    
    func testTwoSessionsIndependentOutput() throws {
        let reg = SessionRegistry()
        let s1 = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        let s2 = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
        let e1 = expectation(description: "s1 sees one"); e1.assertForOverFulfill = false
        let e2 = expectation(description: "s2 sees two"); e2.assertForOverFulfill = false
        var b1 = [UInt8]()
        var b2 = [UInt8]()
        reg.attachOutput(name: s1.name) { chunk, _ in
            b1 += chunk
            if String(decoding: b1, as: UTF8.self).contains("one") { e1.fulfill() }
        }
        reg.attachOutput(name: s2.name) { chunk, _ in
            b2 += chunk
            if String(decoding: b2, as: UTF8.self).contains("two") { e2.fulfill() }
        }
        reg.write(name: s1.name, bytes: bytes("one\n"))
        reg.write(name: s2.name, bytes: bytes("two\n"))
        wait(for: [e1, e2], timeout: 5)
        XCTAssertFalse(String(decoding: b1, as: UTF8.self).contains("two"))
        reg.kill(name: s1.name)
        reg.kill(name: s2.name)
    }
    
    func testCreateFiresSessionAdded() throws {
            let reg = SessionRegistry(clock: { 1 })
            let added = expectation(description: "added")
            reg.onSessionAdded = { _ in added.fulfill() }
            let s = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"])
            wait(for: [added], timeout: 5)
            reg.kill(name: s.name)
        }

    func testRenameMovesEntryAndFiresEvents() throws {
        let reg = SessionRegistry()
        let removed = expectation(description: "removed")
        let added = expectation(description: "added")
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "old")
        reg.onSessionRemoved = { name in if name == "old" { removed.fulfill() } }
        reg.onSessionAdded = { sess in if sess.name == "new" { added.fulfill() } }
        try reg.rename(name: "old", newName: "new")
        wait(for: [removed, added], timeout: 5)
        XCTAssertNil(reg.get(name: "old"))
        XCTAssertEqual(reg.get(name: "new")?.name, "new")
        reg.kill(name: "new")
    }

    func testRenameUnknownThrowsNotFound() throws {
        let reg = SessionRegistry()
        XCTAssertThrowsError(try reg.rename(name: "ghost", newName: "x")) {
            XCTAssertEqual($0 as? RegistryError, .notFound("ghost"))
        }
    }

    func testRenameToTakenThrowsDuplicate() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "a")
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "b")
        XCTAssertThrowsError(try reg.rename(name: "a", newName: "b")) {
            XCTAssertEqual($0 as? RegistryError, .duplicateName("b"))
        }
        reg.kill(name: "a"); reg.kill(name: "b")
    }

    func testBackfillReturnsNilForUnknown() throws {
        let reg = SessionRegistry()
        XCTAssertNil(reg.backfill(name: "ghost", since: 0))
    }

    func testSnapshotScreensShowsSessionOutput() throws {
        let reg = SessionRegistry()
        _ = try reg.create(
            dir: "/tmp", agent: "sh",
            argv: ["/bin/sh", "-c", "printf 'hello-screen'; exec cat"],
            name: "scr"
        )
        waitUntil({ reg.snapshotScreens()["scr"]?.contains("hello-screen") == true },
                  "screen shows output")
        reg.kill(name: "scr")
    }
}
