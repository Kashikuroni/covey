import XCTest
@testable import CoveydCore
import CoveyKit

final class TraceMonitorTests: XCTestCase {
    private var root = ""
    private var claudeRoot: String { "\(root)/claude" }
    private var codexRoot: String { "\(root)/codex/sessions" }
    private var store: String { "\(root)/traces" }
    private let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"
    private let cwd = "/work/app"
    private var jsonl: String { "\(claudeRoot)/-work-app/\(uuid).jsonl" }

    override func setUpWithError() throws {
        root = "\(NSTemporaryDirectory())covey-tracemon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(claudeRoot)/-work-app",
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func entry() -> ModelMonitor.Entry {
        ("s", cwd, "claude", 1_753_170_600, "claude --resume \(uuid)")
    }
    private func line(_ text: String) -> String {
        #"{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }
    private func makeMonitor() -> (TraceMonitor, TraceStore) {
        let s = TraceStore(root: store)
        let m = TraceMonitor(store: s, interval: 5, projectsRoot: claudeRoot,
                             codexSessionsRoot: codexRoot, snapshot: { [self.entry()] })
        return (m, s)
    }

    func testTailsOnlyNewBytesAndAssignsMonotonicSeq() throws {
        try line("first").write(toFile: jsonl, atomically: true, encoding: .utf8)
        let (monitor, store) = makeMonitor()
        var appended: [TraceEvent] = []
        monitor.onTraceAppended = { _, events in appended += events }
        monitor.tick()
        XCTAssertEqual(appended.map(\.seq), [0])
        let handle = FileHandle(forWritingAtPath: jsonl)!
        _ = try handle.seekToEnd(); try handle.write(contentsOf: Data(line("second").utf8))
        try handle.close()
        monitor.tick()
        XCTAssertEqual(appended.map(\.seq), [0, 1], "second tick reads only appended line")
        XCTAssertEqual(store.read(sessionKey: uuid, sinceSeq: 0).map(\.seq), [0, 1])
        XCTAssertEqual(monitor.sessionKey(name: "s"), uuid)
    }
}
