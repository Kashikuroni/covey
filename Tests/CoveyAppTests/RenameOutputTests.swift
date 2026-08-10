import XCTest
@testable import covey
import CoveyKit

/// Issue #5: after a rename the daemon kept publishing live output under the
/// old name, so the pane froze on the attach backfill — typing landed in the
/// session but nothing ever came back ("broken input to agent panel").
/// End-to-end against the real in-process daemon: client, IPC hop and PTY.
final class RenameOutputTests: XCTestCase {
    @MainActor
    func testOutputStillReachesThePaneAfterRename() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let old = model.sessions[0].name
        await model.select(old)

        await model.rename(old, to: "renamed")
        let reselected = await eventually { model.selected == "renamed" }
        XCTAssertTrue(reselected, "rename must carry the selection over")

        var received = ""
        model.setTerminalSink(for: "renamed") { received += String(decoding: $0, as: UTF8.self) }
        await model.sendInput(Array("ping\n".utf8), to: "renamed")

        let echoed = await eventually { received.contains("ping") }
        XCTAssertTrue(echoed, "the renamed session's output never reached the pane")
        await model.kill("renamed")
    }
}
