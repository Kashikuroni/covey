import XCTest
@testable import CoveydCore

final class ModelMonitorTests: XCTestCase {
    private var root = ""       // fake ~/.claude/projects
    private let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"
    private let cwd = "/work/app"
    private var jsonl: String { "\(root)/-work-app/\(uuid).jsonl" }

    override func setUpWithError() throws {
        root = "\(NSTemporaryDirectory())covey-modmon-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: "\(root)/-work-app",
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func assistantLine(_ model: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)"}}"# + "\n"
    }

    private func append(_ line: String) throws {
        let fh = FileHandle(forWritingAtPath: jsonl)!
        defer { try? fh.close() }
        _ = try fh.seekToEnd()
        try fh.write(contentsOf: Data(line.utf8))
    }

    private func makeMonitor(_ sessions: @escaping () -> [ModelMonitor.Entry]) -> ModelMonitor {
        ModelMonitor(projectsRoot: root, snapshot: sessions)
    }

    func testEmitsOnFirstReadAndOnChangeOnly() throws {
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        var sessions: [ModelMonitor.Entry] = [("s", cwd, "claude --resume \(uuid)")]
        let monitor = makeMonitor { sessions }
        let lock = NSLock()
        var events: [(String, String)] = []
        monitor.onModelChanged = { n, m in lock.lock(); events.append((n, m)); lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }

        monitor.tick()
        XCTAssertEqual(count(), 1, "first observation emits")
        XCTAssertEqual(events.last?.1, "claude-fable-5")
        monitor.tick()
        XCTAssertEqual(count(), 1, "unchanged file, no event")
        try append(assistantLine("claude-opus-4-8"))
        monitor.tick()
        XCTAssertEqual(count(), 2, "model switch emits")
        XCTAssertEqual(events.last?.1, "claude-opus-4-8")
        XCTAssertEqual(monitor.current(), ["s": "claude-opus-4-8"])

        sessions = []
        monitor.tick()
        XCTAssertEqual(count(), 2, "pruned session emits nothing")
        XCTAssertEqual(monitor.current(), [:], "removed session is pruned")
    }

    func testUnparsableTailKeepsPreviousReading() throws {
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        let monitor = makeMonitor { [("s", self.cwd, "claude --resume \(self.uuid)")] }
        monitor.tick()
        // Sidechain + synthetic entries only — must not clobber the reading.
        try append(#"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001"}}"# + "\n")
        try append(#"{"type":"assistant","message":{"model":"<synthetic>"}}"# + "\n")
        var emitted = false
        monitor.onModelChanged = { _, _ in emitted = true }
        monitor.tick()
        XCTAssertFalse(emitted, "sidechain/synthetic tail is not a change")
        XCTAssertEqual(monitor.current(), ["s": "claude-fable-5"])
    }

    func testMissingTranscriptThenAppears() throws {
        let monitor = makeMonitor { [("s", self.cwd, "claude --resume \(self.uuid)")] }
        let lock = NSLock()
        var events = 0
        monitor.onModelChanged = { _, _ in lock.lock(); events += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return events }
        monitor.tick()
        XCTAssertEqual(count(), 0, "no transcript yet — silence")
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        monitor.tick()
        XCTAssertEqual(count(), 1, "transcript appeared — badge")
    }

    func testNonClaudeSessionsSkipped() throws {
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        let monitor = makeMonitor { [("term", self.cwd, nil)] }
        var emitted = false
        monitor.onModelChanged = { _, _ in emitted = true }
        monitor.tick()
        XCTAssertFalse(emitted, "resumeCmd == nil is not a claude session")
        XCTAssertEqual(monitor.current(), [:])
    }

    func testPokeEmitsWithoutTick() throws {
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        let monitor = makeMonitor { [] }
        let lock = NSLock()
        var last: String?
        monitor.onModelChanged = { _, m in lock.lock(); last = m; lock.unlock() }
        monitor.poke(name: "s", cwd: cwd, resumeCmd: "claude --resume \(uuid)")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock(); let done = last != nil; lock.unlock()
            if done { break }
            usleep(20_000)
        }
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(last, "claude-fable-5", "poke reads and emits immediately")
    }
}
