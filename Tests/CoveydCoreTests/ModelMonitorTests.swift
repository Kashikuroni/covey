import XCTest
@testable import CoveydCore

final class ModelMonitorTests: XCTestCase {
    private var root = ""
    private var claudeRoot: String { "\(root)/claude" }
    private var codexRoot: String { "\(root)/codex/sessions" }
    private var codexConfig: String { "\(root)/codex/config.toml" }
    private let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"
    private let cwd = "/work/app"
    private var jsonl: String { "\(claudeRoot)/-work-app/\(uuid).jsonl" }

    override func setUpWithError() throws {
        root = "\(NSTemporaryDirectory())covey-modmon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(claudeRoot)/-work-app",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codexRoot,
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
        ModelMonitor(projectsRoot: claudeRoot, codexSessionsRoot: codexRoot,
                     codexConfigPath: codexConfig, snapshot: sessions)
    }

    private func claudeEntry(_ name: String = "s") -> ModelMonitor.Entry {
        (name, cwd, "claude", 1_753_170_600, "claude --resume \(uuid)")
    }

    private func writeCodexRollout(id: String, created: Int64, cwd: String,
                                   models: [String]) throws -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(created))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let directory = "\(codexRoot)/\(formatter.string(from: date))"
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: date)
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\",\"timestamp\":\"\(timestamp)\"}}",
        ] + models.map {
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"\($0)\"}}"
        }
        let path = "\(directory)/rollout-\(id).jsonl"
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testEmitsOnFirstReadAndOnChangeOnly() throws {
        try assistantLine("claude-fable-5").write(toFile: jsonl, atomically: true, encoding: .utf8)
        var sessions: [ModelMonitor.Entry] = [claudeEntry()]
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
        let monitor = makeMonitor { [self.claudeEntry()] }
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
        let monitor = makeMonitor { [self.claudeEntry()] }
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
        let monitor = makeMonitor { [("term", self.cwd, "zsh", 1_753_170_600, nil)] }
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
        monitor.poke(name: "s", cwd: cwd, agent: "claude", created: 1_753_170_600,
                     resumeCmd: "claude --resume \(uuid)")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock(); let done = last != nil; lock.unlock()
            if done { break }
            usleep(20_000)
        }
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(last, "claude-fable-5", "poke reads and emits immediately")
    }

    func testCodexConfiguredFallbackIsReplacedByRolloutModel() throws {
        try "model = \"gpt-5.5\"\n".write(toFile: codexConfig,
                                              atomically: true, encoding: .utf8)
        let created: Int64 = 1_753_170_600
        var sessions: [ModelMonitor.Entry] = [("cx", cwd, "codex", created, nil)]
        let monitor = makeMonitor { sessions }
        var values: [String] = []
        monitor.onModelChanged = { name, model in if name == "cx" { values.append(model) } }

        monitor.tick()
        XCTAssertEqual(values, ["gpt-5.5"])
        _ = try writeCodexRollout(id: "thread-cx", created: created, cwd: cwd,
                                  models: ["gpt-5.6-terra"])
        monitor.tick()
        XCTAssertEqual(values, ["gpt-5.5", "gpt-5.6-terra"])
        XCTAssertEqual(monitor.current()["cx"], "gpt-5.6-terra")

        sessions = []
        monitor.tick()
        XCTAssertNil(monitor.current()["cx"])
    }

    func testTwoCodexSessionsInSameCwdKeepUniqueRolloutsAndEmitChangesOnce() throws {
        let created: Int64 = 1_753_170_600
        let firstPath = try writeCodexRollout(id: "one", created: created, cwd: cwd,
                                              models: ["gpt-5.5"])
        _ = try writeCodexRollout(id: "two", created: created, cwd: cwd,
                                  models: ["gpt-5.6-terra"])
        let sessions: [ModelMonitor.Entry] = [
            ("cx-1", cwd, "codex", created, nil),
            ("cx-2", cwd, "codex", created, nil),
        ]
        let monitor = makeMonitor { sessions }
        var events: [(String, String)] = []
        monitor.onModelChanged = { events.append(($0, $1)) }

        monitor.tick()
        XCTAssertEqual(monitor.current()["cx-1"], "gpt-5.5")
        XCTAssertEqual(monitor.current()["cx-2"], "gpt-5.6-terra")
        try Data("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.7\"}}\n".utf8)
            .append(to: URL(fileURLWithPath: firstPath))
        monitor.tick()
        monitor.tick()
        XCTAssertEqual(monitor.current()["cx-1"], "gpt-5.7")
        XCTAssertEqual(events.filter { $0.0 == "cx-1" && $0.1 == "gpt-5.7" }.count, 1)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
