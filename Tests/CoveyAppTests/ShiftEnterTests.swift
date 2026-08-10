import XCTest
@testable import covey
import CoveyKit

/// Issue #4: SwiftTerm sends a bare CR for ⇧Enter — the shift only shows up
/// under the kitty keyboard protocol, which the agents do not turn on — so
/// Claude Code read it as a plain Enter and submitted instead of breaking the
/// line. It has to arrive as ESC CR, the same bytes ⌥Enter already sends and
/// what Claude Code's own /terminal-setup binds.
final class ShiftEnterTests: XCTestCase {
    @MainActor
    func testShiftEnterReachesTheAgentAsEscapeReturn() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.create(dir: "/usr", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = model.sessions[0].name
        await model.select(name)

        var received: [UInt8] = []
        model.setTerminalSink(for: name) { received += $0 }
        // Let the attach preamble land and drop it: it is full of escape
        // sequences of its own.
        try await Task.sleep(nanoseconds: 300_000_000)
        received = []

        model.apply(.sendShiftEnter)

        // `cat` writes the line straight back, so ESC CR returns as ESC CR LF.
        let got = await eventually { Self.containsPair(received, 0x1b, 0x0d) }
        XCTAssertTrue(got, "⇧Enter reached the session as something other than ESC CR")
        await model.kill(name)
    }

    private static func containsPair(_ bytes: [UInt8], _ first: UInt8, _ second: UInt8) -> Bool {
        guard bytes.count > 1 else { return false }
        return (0..<(bytes.count - 1)).contains { bytes[$0] == first && bytes[$0 + 1] == second }
    }
}
