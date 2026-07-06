import XCTest
@testable import CoveydCore
import CoveyKit

final class GitMonitorTests: XCTestCase {
    private var repo = ""

    override func setUpWithError() throws {
        repo = "\(NSTemporaryDirectory())covey-gitmon-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try sh("git -C '\(repo)' init -q -b main")
        try sh("git -C '\(repo)' -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private func sh(_ cmd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitOps.GitError("sh failed: \(cmd)") }
    }

    func testEmitsOnChangeOnly() throws {
        var sessions = [(name: "s", dir: repo)]
        let monitor = GitMonitor(snapshot: { sessions })
        let lock = NSLock()
        var events: [(String, GitInfo?)] = []
        monitor.onGitChanged = { n, g in lock.lock(); events.append((n, g)); lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }
        monitor.tick()
        XCTAssertEqual(count(), 1, "first observation emits")
        XCTAssertEqual(events.last?.1?.branch, "main")
        monitor.tick()
        XCTAssertEqual(count(), 1, "no change, no event")
        try "x\n".write(toFile: "\(repo)/tracked.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(repo)' add tracked.txt && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q -m t")
        try "x\ny\n".write(toFile: "\(repo)/tracked.txt", atomically: true, encoding: .utf8)
        monitor.tick()
        XCTAssertEqual(count(), 2, "diff change emits")
        sessions = []
        monitor.tick()
        XCTAssertEqual(count(), 2, "pruned session emits nothing")
    }

    // Restart regression: the registry drops session.git on respawn, but the
    // monitor's prev map still holds the old value — without forget() the
    // unchanged reading never re-emits and the card stays git-less forever.
    func testForgetReemitsUnchangedInfo() {
        let monitor = GitMonitor(snapshot: { [(name: "s", dir: self.repo)] })
        let lock = NSLock()
        var events = 0
        monitor.onGitChanged = { _, _ in lock.lock(); events += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return events }
        monitor.tick()
        XCTAssertEqual(count(), 1)
        monitor.tick()
        XCTAssertEqual(count(), 1, "stable info stays silent")
        monitor.forget(name: "s")
        monitor.tick()
        XCTAssertEqual(count(), 2, "forget forces a re-emit")
    }

    // A non-repo dir reads as nil; with no previous entry that is NOT a
    // change — emitting here raced manual/monitor events and wiped git info.
    func testNonRepoNeverEmitsNilOnFirstSight() {
        let monitor = GitMonitor(snapshot: { [(name: "s", dir: "/tmp")] })
        let lock = NSLock()
        var events = 0
        monitor.onGitChanged = { _, _ in lock.lock(); events += 1; lock.unlock() }
        monitor.tick()
        monitor.poke(name: "s", dir: "/tmp")
        monitor.tick()
        Thread.sleep(forTimeInterval: 0.3)   // let the async poke drain
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(events, 0, "nil reading with no prev entry is not a change")
    }

    // Create/restart must not wait out the 5s poll interval: poke reads one
    // session immediately (async on the monitor queue).
    func testPokeEmitsWithoutTick() {
        let monitor = GitMonitor(snapshot: { [] })
        let lock = NSLock()
        var last: GitInfo??
        monitor.onGitChanged = { _, g in lock.lock(); last = g; lock.unlock() }
        monitor.poke(name: "s", dir: repo)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock(); let done = last != nil; lock.unlock()
            if done { break }
            usleep(20_000)
        }
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(last??.branch, "main", "poke reads and emits immediately")
    }
}
