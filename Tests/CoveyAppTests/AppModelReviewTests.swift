import XCTest
import CoveyKit
import CoveydCore
@testable import covey

final class AppModelReviewTests: XCTestCase {
    @MainActor
    func testReviewTargetsAreAgentSessionsOfTheProject() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/tmp", agent: "zsh", argv: ["/bin/cat"], name: "shell")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "elsewhere")
        let (model, _) = try makeModel(daemon)
        await model.start()

        let targets = model.reviewTargets(projectRoot: "/tmp")
        XCTAssertEqual(targets.map(\.name), ["agent"])
        XCTAssertEqual(targets.first?.dir, "/tmp")
        XCTAssertEqual(targets.first?.status, .idle)
        for name in ["agent", "shell", "elsewhere"] { daemon.registry.kill(name: name) }
    }

    @MainActor
    func testSendToSessionWritesIntoThePTY() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()

        try await model.sendToSession("agent", bytes: Array("hello-review\r".utf8))
        let echoed = await eventually {
            daemon.registry.snapshotScreens()["agent"]?.contains("hello-review") == true
        }
        XCTAssertTrue(echoed)
        daemon.registry.kill(name: "agent")
    }
}
