import XCTest
import CoveyGit
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

    @MainActor
    func testReviewWindowFocusDisablesCatalogCommands() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        XCTAssertTrue(model.commandAvailability(.newSession).isEnabled)
        model.reviewWindowFocused = true
        XCTAssertEqual(model.commandAvailability(.newSession), .disabled(reason: "Review window is focused"))
        XCTAssertFalse(model.commandAvailability(.closeTerminalSplit).isEnabled)
        model.reviewWindowFocused = false
        XCTAssertTrue(model.commandAvailability(.newSession).isEnabled)
    }

    @MainActor
    func testOpenReviewRequestsTheWindowForTheSessionsToplevel() async throws {
        let repo = "\(NSTemporaryDirectory())covey-open-review-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "mkdir -p '\(repo)' && git -C '\(repo)' init -q -b main && git -C '\(repo)' -c user.email=t@t -c user.name=t commit -q --allow-empty -m init"]
        try p.run()
        p.waitUntilExit()

        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: repo, agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        daemon.gitMonitor.tick()
        let hasGit = await eventually { model.sessions.first?.git != nil }
        XCTAssertTrue(hasGit)

        model.perform(.openReview)
        let requested = await eventually { model.reviewWindowRequest != nil }
        XCTAssertTrue(requested)
        let key = try XCTUnwrap(model.reviewWindowRequest)
        XCTAssertEqual(key, ReviewWindowKey(worktree: try XCTUnwrap(Repository(at: repo).toplevel())))
        XCTAssertEqual(model.reviewLaunch(for: key), ReviewLaunch(originSession: "agent", projectRoot: repo))
        model.consumeReviewWindowRequest()
        XCTAssertNil(model.reviewWindowRequest)
        daemon.registry.kill(name: "agent")
    }
}
