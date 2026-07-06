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

    // Regression: interactive shells IGNORE SIGTERM, so kill() must escalate via
    // SIGHUP (and SIGKILL). This child explicitly traps SIGTERM, so it would
    // survive a SIGTERM-only kill and the session would never exit.
    func testKillTerminatesSigtermIgnoringChild() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh",
                           argv: ["/bin/sh", "-c", "trap '' TERM; exec sleep 60"], name: "k")
        let exited = expectation(description: "exit after SIGHUP/SIGKILL")
        reg.onExit = { name, _ in if name == "k" { exited.fulfill() } }
        reg.kill(name: "k")
        wait(for: [exited], timeout: 5)
        XCTAssertTrue(reg.list().isEmpty)
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

    func testRestartRespawnsSameEntry() throws {
        let reg = SessionRegistry()
        let restarted = expectation(description: "restarted")
        var updated: Session?
        reg.onRestarted = { s in updated = s; restarted.fulfill() }
        reg.onExit = { _, _ in XCTFail("restart must not emit exit") }
        reg.onSessionRemoved = { _ in XCTFail("restart must not remove") }
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r1")
        try reg.restart(name: "r1")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(updated?.name, "r1")
        XCTAssertEqual(updated?.dir, "/usr", "no override: same dir")
        XCTAssertEqual(reg.list().map(\.name), ["r1"], "entry survived the restart")
        reg.onExit = nil; reg.onSessionRemoved = nil
        reg.kill(name: "r1")
    }

    func testRestartDirOverride() throws {
        let reg = SessionRegistry()
        let restarted = expectation(description: "restarted")
        var updated: Session?
        reg.onRestarted = { s in updated = s; restarted.fulfill() }
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r2")
        try reg.restart(name: "r2", dir: "/tmp")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(updated?.dir, "/tmp", "return-to-root respawns in the override dir")
        reg.kill(name: "r2")
    }

    func testRestartMissingDirThrows() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"], name: "r3")
        XCTAssertThrowsError(try reg.restart(name: "r3", dir: "/definitely/not/here")) {
            XCTAssertEqual($0 as? RegistryError, .dirMissing("/definitely/not/here"))
        }
        XCTAssertThrowsError(try reg.restart(name: "ghost")) {
            XCTAssertEqual($0 as? RegistryError, .notFound("ghost"))
        }
        reg.kill(name: "r3")
    }

    func testRestartClaudeUsesResumeArgv() throws {
        // A claude session (resumeCmd set) respawns through the resume command
        // with the 15.1 fallback wrapper — visible in the persisted argv.
        // Capture the meta the moment it carries the respawn argv: the
        // respawned sh may exit (claude absent) and persist again before the
        // assertion runs.
        var claudeMeta: SessionMeta?
        let reg = SessionRegistry(onPersist: { metas in
            if let m = metas.first(where: { $0.name == "cl" }), m.argv.first == "/bin/sh" {
                claudeMeta = m
            }
        })
        let restarted = expectation(description: "restarted")
        reg.onRestarted = { _ in restarted.fulfill() }
        _ = try reg.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                           name: "cl", resumeCmd: "claude --resume 12345678-1234-1234-1234-123456789abc")
        try reg.restart(name: "cl")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(claudeMeta?.argv.first, "/bin/sh")
        XCTAssertTrue(claudeMeta?.argv.last?.contains("--resume 12345678") == true,
                      "\(claudeMeta?.argv ?? [])")
        XCTAssertTrue(claudeMeta?.argv.last?.contains("|| ") == true, "fallback wrapper present")
        reg.kill(name: "cl")
    }

    func testRestartKeepsCompanionAlive() throws {
        let reg = SessionRegistry()
        let parent = try reg.create(dir: "/usr", agent: "claude",
                                    argv: ["/bin/cat"], name: "agent")
        _ = try reg.create(dir: "/usr", agent: "sh", argv: ["/bin/cat"],
                           name: "agent+sh", companionOf: parent.name)
        let restarted = expectation(description: "restarted")
        reg.onRestarted = { s in
            XCTAssertEqual(s.name, "agent")
            restarted.fulfill()
        }
        reg.onExit = { name, _ in XCTFail("restart must not emit exit (got \(name))") }
        reg.onSessionRemoved = { name in XCTFail("restart must not remove \(name)") }
        try reg.restart(name: "agent")
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(reg.companionName(of: "agent"), "agent+sh",
                       "companion must survive the parent's restart")
        XCTAssertNotNil(reg.get(name: "agent+sh"))
        reg.onExit = nil
        reg.onSessionRemoved = nil
        reg.kill(name: "agent")
    }

    func testExitRefreshesResumeCmdFromOutput() throws {
        // claude prints its resume hint on exit; the registry re-reads it so
        // recents (and the next restart) carry the post-/clear uuid.
        let reg = SessionRegistry()
        let exited = expectation(description: "exited")
        var upserted: Session?
        reg.onSessionAdded = { s in
            if s.resumeCmd != "claude --resume old" { upserted = s }
        }
        reg.onExit = { _, _ in exited.fulfill() }
        let hint = "claude --resume 12345678-1234-1234-1234-123456789abc"
        _ = try reg.create(dir: "/tmp", agent: "claude",
                           argv: ["/bin/sh", "-c", "echo '\(hint)'"],
                           name: "cl2", resumeCmd: "claude --resume old")
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(upserted?.resumeCmd, hint, "fresh hint upserted before exited")
    }

    func testAutoNamesHaveNoGaps() throws {
        let reg = SessionRegistry()
        let a = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "explicit")
        XCTAssertThrowsError(
            try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "explicit"))
        let b = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        XCTAssertEqual(a.name, "s-1")
        XCTAssertEqual(b.name, "s-2",
                       "explicit names and failed creates must not consume auto numbers")
        for s in reg.list() { reg.kill(name: s.name) }
    }

    func testAutoNameSkipsExplicitCollision() throws {
        let reg = SessionRegistry()
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "s-1")
        let a = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"])
        XCTAssertEqual(a.name, "s-2")
        for s in reg.list() { reg.kill(name: s.name) }
    }

    final class PersistSpy {
        private let lock = NSLock()
        private var snapshots: [[SessionMeta]] = []
        func record(_ metas: [SessionMeta]) { lock.lock(); snapshots.append(metas); lock.unlock() }
        var last: [SessionMeta]? { lock.lock(); defer { lock.unlock() }; return snapshots.last }
    }

    func testCompanionCreateCascadeKillAndRename() throws {
        let spy = PersistSpy()
        let reg = SessionRegistry(onPersist: spy.record)
        let parent = try reg.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"],
                                    name: "agent")
        let comp = try reg.create(dir: "/tmp", agent: "zsh", argv: ["/bin/cat"],
                                  name: "\(parent.name)+sh", companionOf: parent.name)
        XCTAssertEqual(comp.companionOf, "agent")
        XCTAssertEqual(reg.companionName(of: "agent"), "agent+sh")

        // persistNow must not include companions (they never become lost).
        XCTAssertEqual(spy.last?.map(\.name), ["agent"])

        // rename cascades: the companion follows the parent's name.
        try reg.rename(name: "agent", newName: "renamed")
        XCTAssertEqual(reg.companionName(of: "renamed"), "renamed+sh")
        XCTAssertEqual(reg.get(name: "renamed+sh")?.companionOf, "renamed")

        // kill cascades to the companion.
        reg.kill(name: "renamed")
        waitUntil({ reg.list().isEmpty }, "cascade kill removes both")
    }

    func testPersistCallbackTracksLifecycle() throws {
        let spy = PersistSpy()
        let reg = SessionRegistry(clock: { 7 }, onPersist: spy.record)
        _ = try reg.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "a")
        XCTAssertEqual(spy.last?.map(\.name), ["a"])
        XCTAssertEqual(spy.last?.first?.argv, ["/bin/cat"])
        XCTAssertEqual(spy.last?.first?.created, 7)
        try reg.rename(name: "a", newName: "b")
        XCTAssertEqual(spy.last?.map(\.name), ["b"])
        reg.kill(name: "b")
        waitUntil({ reg.list().isEmpty }, "exit removes entry")
        waitUntil({ spy.last?.isEmpty == true }, "exit persists empty registry")
    }

    func testPersistedEntriesBecomeLostAndClear() {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let spy = PersistSpy()
        let reg = SessionRegistry(persisted: [meta], onPersist: spy.record)
        XCTAssertEqual(reg.lost, [meta])
        XCTAssertTrue(reg.list().isEmpty, "lost sessions are never respawned")
        reg.clearLost()
        XCTAssertTrue(reg.lost.isEmpty)
        XCTAssertEqual(spy.last, [])
    }

    func testPersistIncludesLostUntilClaimed() throws {
        let meta = SessionMeta(name: "old", dir: "/tmp", agent: "claude",
                               argv: ["claude"], created: 1)
        let spy = PersistSpy()
        let reg = SessionRegistry(persisted: [meta], onPersist: spy.record)
        _ = try reg.create(dir: "/a", agent: "sh", argv: ["/bin/cat"], name: "new")
        XCTAssertEqual(Set(spy.last?.map(\.name) ?? []), ["new", "old"],
                       "unclaimed lost sessions must survive a second daemon restart")
        reg.kill(name: "new")
        waitUntil({ reg.list().isEmpty }, "cleanup")
    }

    func testResumeAndWorktreeRepoPersistIntoMeta() throws {
        let spy = PersistSpy()
        let reg = SessionRegistry(onPersist: spy.record)
        _ = try reg.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "r",
                           worktreeRepo: "/repo", resumeCmd: "claude --resume u")
        XCTAssertEqual(spy.last?.first?.worktreeRepo, "/repo")
        XCTAssertEqual(spy.last?.first?.resumeCmd, "claude --resume u")
        reg.kill(name: "r")
        waitUntil({ reg.list().isEmpty }, "cleanup")
    }

    func testSecondLifeSeesFirstLifeSessionsAsLost() throws {
        // Integration with RegistryStore: the daemon-restart scenario.
        let path = "\(NSTemporaryDirectory())covey-registry-\(UInt32.random(in: 0..<UInt32.max)).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RegistryStore(path: path)
        let first = SessionRegistry(persisted: store.load(), onPersist: { store.save($0) })
        _ = try first.create(dir: "/tmp", agent: "sh", argv: ["/bin/cat"], name: "s1")
        let second = SessionRegistry(persisted: store.load(), onPersist: { store.save($0) })
        XCTAssertEqual(second.lost.map(\.name), ["s1"])
        first.kill(name: "s1")
        waitUntil({ first.list().isEmpty }, "cleanup")
    }
}
