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
}
