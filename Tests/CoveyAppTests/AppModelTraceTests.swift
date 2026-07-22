import XCTest
@testable import covey
import CoveyKit

@MainActor
final class AppModelTraceTests: XCTestCase {
    private let uuid = "0b154175-0f2e-43e8-b5b0-97ec3cb0e6a4"

    /// Writes a fake Claude transcript (main + one subagent line) for a
    /// session whose cwd is "/usr" under the daemon's fake projects root.
    private func writeTranscript(_ daemon: TestDaemon) throws {
        let dir = "\(daemon.modelRoot)/-usr"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let main = #"{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"main"}]}}"#
        let sub = #"{"type":"assistant","uuid":"a","isSidechain":true,"message":{"model":"m","content":[{"type":"text","text":"sub"}]}}"#
        try (main + "\n" + sub + "\n")
            .write(toFile: "\(dir)/\(uuid).jsonl", atomically: true, encoding: .utf8)
    }

    func testTraceModeStreamsEventsAndFiltersBySubagent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        try writeTranscript(daemon)

        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = try daemon.registry.create(dir: "/usr", agent: "claude", argv: ["/bin/cat"],
                                       name: "s", resumeCmd: "claude --resume \(uuid)")
        _ = await eventually { model.sessions.contains { $0.name == "s" } }
        daemon.traceMonitor.tick()   // persist backlog to the store

        await model.select("s")
        model.setShowInspector(true)
        model.setInspectorMode(.trace)   // subscribes; backlog fills traceEvents

        let filled = await eventually { model.traceEvents.count >= 2 }
        XCTAssertTrue(filled, "trace backlog streamed into the model")
        XCTAssertGreaterThan(model.traceStoreBytes, 0)

        let sub = model.traceEvents.first { $0.agent.id != nil }?.agent
        XCTAssertNotNil(sub, "subagent line produced a non-main agent")
        model.setTraceAgentFilter(sub)
        XCTAssertTrue(model.visibleTraceEvents.allSatisfy { $0.agent == sub })
        model.setTraceAgentFilter(nil)
        XCTAssertEqual(model.visibleTraceEvents.count, model.traceEvents.count)
        await model.kill("s")
    }

    func testFocusZoneTraceOpensInspectorInTraceMode() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        model.setShowInspector(true)
        model.focusZone(.trace)
        XCTAssertEqual(model.inspectorMode, .trace)
        XCTAssertEqual(model.focus, .inspector)
    }
}
