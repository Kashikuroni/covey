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
    func testToggleOpensTheSelectedSessionsWorktreeAndComesBack() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        let reviews = ReviewFixture(model)
        XCTAssertEqual(model.windowMode, .sessions, "covey always starts on the sessions")
        XCTAssertNil(model.review)

        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .review)
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.worktree, "/tmp")
        XCTAssertEqual(review.projectRoot, "/tmp")
        XCTAssertEqual(review.originSession, "agent")
        XCTAssertEqual(review.phase, .ready)
        XCTAssertTrue(review.isVisible)

        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .sessions)
        XCTAssertIdentical(model.review, review, "the review outlives the trip back")
        XCTAssertFalse(review.isVisible, "no git polling behind the sessions")
        XCTAssertEqual(reviews.built.count, 1)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testTheSameWorktreeReusesTheReviewAndChecksFreshness() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        let reviews = ReviewFixture(model)

        await model.toggleReview()
        let review = try XCTUnwrap(model.review)
        review.composer = ReviewComposer(anchor: LineAnchor(path: "a.swift", side: .new, line: 1, lineText: "x"),
                                         draft: "half a thought")
        await model.toggleReview()
        let checks = reviews.git.fingerprintCalls

        await model.toggleReview()
        XCTAssertIdentical(model.review, review)
        XCTAssertEqual(review.composer?.draft, "half a thought", "drafts survive the round trip")
        XCTAssertEqual(reviews.git.fingerprintCalls, checks + 1, "entering Review checks freshness at once")
        XCTAssertEqual(reviews.built.count, 1)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testAnotherWorktreeFlushesTheOldReviewAndStartsANewOne() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "other")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        let reviews = ReviewFixture(model)

        await model.toggleReview()
        let first = try XCTUnwrap(model.review)
        first.record.files["a.swift"]?.state = .reviewed
        first.persist()
        let firstStore = try XCTUnwrap(reviews.stores["/tmp"])
        XCTAssertEqual(firstStore.writeCount, 0, "precondition: the save is still pending")

        await model.openReview(ReviewOpening(worktree: "/usr", projectRoot: "/usr", originSession: "other"))
        let second = try XCTUnwrap(model.review)
        XCTAssertNotIdentical(second, first)
        XCTAssertEqual(second.worktree, "/usr")
        XCTAssertEqual(second.originSession, "other")
        XCTAssertEqual(model.windowMode, .review)
        XCTAssertEqual(firstStore.writeCount, 1, "the replaced review was flushed to disk")
        daemon.registry.kill(name: "agent")
        daemon.registry.kill(name: "other")
    }

    @MainActor
    func testOutsideGitTheToggleToastsAndStaysOnTheSessions() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/bin", agent: "claude", argv: ["/bin/cat"], name: "plain")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("plain")
        let reviews = ReviewFixture(model)

        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .sessions)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.toast, "Not a Git repository: /bin")
        XCTAssertTrue(reviews.built.isEmpty)
        daemon.registry.kill(name: "plain")
    }

    @MainActor
    func testWithoutASelectionTheToggleBringsBackTheLiveReview() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select(nil)
        _ = ReviewFixture(model)
        XCTAssertEqual(model.commandAvailability(.toggleReview), .disabled(reason: "No session selected"))
        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .sessions, "nothing to review")

        await model.select("agent")
        await model.toggleReview()
        let review = try XCTUnwrap(model.review)
        await model.toggleReview()
        await model.select(nil)
        XCTAssertTrue(model.commandAvailability(.toggleReview).isEnabled)
        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .review)
        XCTAssertIdentical(model.review, review)
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testReviewModeDisablesSessionCommandsButNotTheToggle() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        _ = ReviewFixture(model)
        XCTAssertTrue(model.commandAvailability(.killSession).isEnabled)

        await model.toggleReview()
        for command in [AppCommand.selectSession1, .killSession, .renameSession,
                        .splitTerminalVertically, .focusAgent] {
            XCTAssertEqual(model.commandAvailability(command), .disabled(reason: "Review is open"), "\(command)")
        }
        XCTAssertTrue(model.commandAvailability(.toggleReview).isEnabled)
        model.perform(.killSession)
        XCTAssertNil(model.modal, "a disabled command does nothing")
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testPollingFollowsTheModeAndTheWindowsOcclusion() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        _ = ReviewFixture(model)

        await model.toggleReview()
        let review = try XCTUnwrap(model.review)
        XCTAssertTrue(review.isVisible)
        model.setMainWindowOccluded(true)
        XCTAssertFalse(review.isVisible)
        model.setMainWindowOccluded(false)
        XCTAssertTrue(review.isVisible)
        model.leaveReview()
        XCTAssertFalse(review.isVisible)
        model.setMainWindowOccluded(false)
        XCTAssertFalse(review.isVisible, "uncovering the window does not wake a hidden review")
        daemon.registry.kill(name: "agent")
    }

    @MainActor
    func testWorktreeChoicesAreTheAgentSessionsWorktrees() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "zsh", argv: ["/bin/cat"], name: "a-shell")
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "b-agent")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "other")
        _ = try daemon.registry.create(dir: "/bin", agent: "claude", argv: ["/bin/cat"], name: "plain")
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = ReviewFixture(model)

        let choices = await model.reviewWorktreeChoices()
        XCTAssertEqual(Set(choices.map(\.worktree)), ["/tmp", "/usr"], "/bin is outside git")
        XCTAssertEqual(choices.first { $0.worktree == "/tmp" }?.session, "b-agent",
                       "the shell never becomes the send target")
        for name in ["a-shell", "b-agent", "other", "plain"] { daemon.registry.kill(name: name) }
    }

    /// A session sits in a subdirectory of its worktree: the toplevel git
    /// reports for that exact directory is what the picker offers.
    @MainActor
    func testWorktreeChoicesAreResolvedFromTheSessionsOwnDirectory() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/usr/bin", agent: "claude", argv: ["/bin/cat"], name: "deep")
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = ReviewFixture(model)
        // Answers only for the session's own directory, never for its toplevel.
        model.resolveReviewWorktree = { dir in ["/usr/bin": "/usr"][dir] }

        let choices = await model.reviewWorktreeChoices()
        XCTAssertEqual(choices.map(\.worktree), ["/usr"])
        XCTAssertEqual(choices.map(\.session), ["deep"])
        daemon.registry.kill(name: "deep")
    }

    /// ⌥⌘R pressed again (for another session) before git answered the first
    /// press: only the newest entry lands.
    @MainActor
    func testALateToplevelFromASupersededEntryIsDropped() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "other")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        let reviews = ReviewFixture(model)
        let gate = CallGate()
        model.resolveReviewWorktree = { dir in
            if dir == "/tmp" { try? await gate.hold() }
            return ["/tmp": "/tmp", "/usr": "/usr"][dir]
        }

        let first = Task { await model.toggleReview() }
        await gate.waitUntilArrived()
        await model.select("other")
        await model.toggleReview()
        XCTAssertEqual(model.review?.worktree, "/usr")

        gate.release()
        await first.value
        XCTAssertEqual(model.review?.worktree, "/usr", "the slow first press lost")
        XCTAssertEqual(reviews.built.count, 1)
        daemon.registry.kill(name: "agent")
        daemon.registry.kill(name: "other")
    }

    /// Closing a sheet, the palette or the limits overlay hands the keyboard
    /// back to the focused terminal — never while Review hides it.
    @MainActor
    func testReviewKeepsTheKeyboardOffTheHiddenTerminals() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        _ = ReviewFixture(model)
        var commands: [AppModel.TerminalCommand] = []
        model.setTerminalCommandHandler(for: "agent") { commands.append($0) }
        model.setFocus(.terminal)

        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [.focus], "precondition: the sessions hand focus back")

        await model.toggleReview()
        commands = []
        model.restoreCommandPaletteTerminalFocus()
        XCTAssertEqual(commands, [])
        daemon.registry.kill(name: "agent")
    }

    /// `focusPane` (a split leaf's session exits, a shell finishes spawning)
    /// keeps its bookkeeping while Review is open so the pane is refocused on
    /// return, but never makes the hidden terminal the first responder.
    @MainActor
    func testFocusingAPaneWhileReviewIsOpenKeepsTheKeyboardOffTheHiddenTerminal() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        _ = ReviewFixture(model)
        var commands: [AppModel.TerminalCommand] = []
        model.setTerminalCommandHandler(for: "agent") { commands.append($0) }

        model.focusPane("agent")
        XCTAssertEqual(commands, [.focus], "precondition: the sessions hand the keyboard to the pane")

        await model.toggleReview()
        commands = []
        model.setFocus(.sessions)
        model.focusPane("agent")
        XCTAssertEqual(commands, [], "no hidden terminal takes the keyboard")
        XCTAssertEqual(model.focusedPane, "agent", "the pane is still remembered for the way back")
        XCTAssertEqual(model.focus, .terminal)
        daemon.registry.kill(name: "agent")
    }
}

/// Wires an `AppModel` for Review without real git: `/tmp` and `/usr` are
/// worktrees (each its own toplevel), anything else is outside git; reviews
/// run on one fake git and a store per worktree whose saves stay pending.
@MainActor
final class ReviewFixture {
    let git = FakeReviewGit()
    private(set) var built: [ReviewModel] = []
    private(set) var stores: [String: ReviewStore] = [:]

    init(_ model: AppModel) {
        git.state = comparisonState([changed("a.swift")])
        model.resolveReviewWorktree = { dir in ["/tmp": "/tmp", "/usr": "/usr"][dir] }
        // Strong capture: tests often drop the fixture right after wiring it.
        model.reviewModelFactory = { [self] opening in
            let store = ReviewStore(
                root: "\(NSTemporaryDirectory())covey-reviews-\(UInt32.random(in: 0..<UInt32.max))",
                debounce: 60)
            stores[opening.worktree] = store
            let review = ReviewModel(worktree: opening.worktree, projectRoot: opening.projectRoot,
                                     originSession: opening.originSession, git: git, store: store,
                                     directory: nil)
            built.append(review)
            return review
        }
    }
}
