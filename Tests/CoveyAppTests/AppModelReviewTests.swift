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
        await model.leaveReview()
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

    private func temporaryWorktree() -> String {
        "\(NSTemporaryDirectory())covey-worktree-\(UInt32.random(in: 0..<UInt32.max))"
    }

    /// A worktree removed while its review waited behind the sessions: the
    /// way back says so instead of showing the dead comparison as current.
    @MainActor
    func testAVanishedWorktreeIsMissingOnTheWayBack() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = ReviewFixture(model)
        let dir = temporaryWorktree()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await model.openReview(ReviewOpening(worktree: dir, projectRoot: dir, originSession: nil))
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.phase, .ready, "precondition: the review loaded")
        await model.leaveReview()

        try FileManager.default.removeItem(atPath: dir)
        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .review)
        XCTAssertIdentical(model.review, review)
        XCTAssertEqual(review.phase, .missingWorktree)
    }

    /// The other way round: the worktree is back (checked out again), so
    /// the way back loads it.
    @MainActor
    func testAWorktreeThatIsBackLoadsOnTheWayBack() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        _ = ReviewFixture(model)
        let dir = temporaryWorktree()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await model.openReview(ReviewOpening(worktree: dir, projectRoot: dir, originSession: nil))
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.phase, .missingWorktree, "precondition: nothing there yet")
        await model.leaveReview()

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await model.toggleReview()
        XCTAssertIdentical(model.review, review)
        XCTAssertEqual(review.phase, .ready)
    }

    /// ⌥⌘R with nothing selected brings back the live review; a toplevel
    /// that git resolves late for an earlier press must not replace it.
    @MainActor
    func testALateToplevelCannotReplaceTheReviewJustShown() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "other")
        let (model, _) = try makeModel(daemon)
        await model.start()
        let reviews = ReviewFixture(model)
        await model.select("other")
        await model.toggleReview()
        let live = try XCTUnwrap(model.review)
        await model.toggleReview()

        let gate = CallGate()
        model.resolveReviewWorktree = { dir in
            if dir == "/tmp" { try? await gate.hold() }
            return ["/tmp": "/tmp", "/usr": "/usr"][dir]
        }
        await model.select("agent")
        let first = Task { await model.toggleReview() }
        await gate.waitUntilArrived()
        await model.select(nil)
        await model.toggleReview()
        XCTAssertEqual(model.windowMode, .review)
        XCTAssertIdentical(model.review, live, "precondition: the live review is back")

        gate.release()
        await first.value
        XCTAssertIdentical(model.review, live, "the slow earlier press lost")
        XCTAssertEqual(reviews.built.map(\.worktree), ["/usr"])
        daemon.registry.kill(name: "agent")
        daemon.registry.kill(name: "other")
    }

    /// Picking a worktree in the Review top bar selects its session too (the
    /// pane behind Review swaps while parked), so ⌥⌘R back and forth comes
    /// back to the picked review instead of replacing it with the old
    /// selection's.
    @MainActor
    func testPickingAWorktreeSelectsItsSessionForTheRoundTrip() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/usr", agent: "codex", argv: ["/bin/cat"], name: "other")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        let reviews = ReviewFixture(model)
        await model.toggleReview()

        await model.pickReviewWorktree(ReviewWorktreeChoice(worktree: "/usr", projectRoot: "/usr",
                                                            session: "other"))
        XCTAssertEqual(model.selected, "other", "the picked worktree's session is the selection")
        XCTAssertEqual(model.windowMode, .review, "a selection change, not a mode switch")
        let picked = try XCTUnwrap(model.review)
        XCTAssertEqual(picked.worktree, "/usr")

        await model.toggleReview()
        await model.toggleReview()
        XCTAssertIdentical(model.review, picked, "⌥⌘R back and forth keeps the picked review")
        XCTAssertEqual(reviews.built.map(\.worktree), ["/tmp", "/usr"])
        daemon.registry.kill(name: "agent")
        daemon.registry.kill(name: "other")
    }

    /// "Sent to <session> · ⌥⌘R to watch": the trip back shows the session
    /// the review went to — once; later trips leave the selection alone.
    @MainActor
    func testTheTripBackAfterASendShowsTheSessionItWentTo() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        _ = try daemon.registry.create(dir: "/tmp", agent: "claude", argv: ["/bin/cat"], name: "agent")
        _ = try daemon.registry.create(dir: "/tmp", agent: "codex", argv: ["/bin/cat"], name: "helper")
        let (model, _) = try makeModel(daemon)
        await model.start()
        await model.select("agent")
        _ = ReviewFixture(model)
        await model.toggleReview()
        let review = try XCTUnwrap(model.review)
        // The fixture's reviews send nowhere; this one sends through the app.
        review.directory = model
        review.enterDelay = .zero
        review.record.issues = [ReviewIssue(
            id: 1, anchor: LineAnchor(path: "a.swift", side: .new, line: 1, lineText: "x"),
            title: "t", body: "t", severity: .low, status: .open, createdAt: Date())]
        review.setTarget("helper")
        review.beginSend()
        XCTAssertTrue(review.canSend, "precondition: helper can receive the review")
        await review.send()
        XCTAssertEqual(review.toasts.last?.text, "Sent to helper · ⌥⌘R to watch")

        await model.leaveReview()
        XCTAssertEqual(model.windowMode, .sessions)
        XCTAssertEqual(model.selected, "helper", "the trip back shows the agent the review went to")

        await model.select("agent")
        await model.toggleReview()
        await model.leaveReview()
        XCTAssertEqual(model.selected, "agent", "only the first trip back follows the send")
        daemon.registry.kill(name: "agent")
        daemon.registry.kill(name: "helper")
    }

    /// The limits overlay opened over Review (its chip stays clickable) owns
    /// the keys, but only its own: with vim mode off the sessions router maps
    /// ⇧Tab and ⇧Enter to bytes for the focused terminal — hidden behind
    /// Review. Esc closes the overlay whatever the vim mode.
    @MainActor
    func testTheLimitsOverlayOverReviewSendsNothingToTheHiddenAgent() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let (model, _) = try makeModel(daemon)
        await model.start()
        // Created through the client: only then does live output flow.
        await model.create(dir: "/tmp", agent: "/bin/cat")
        _ = await eventually { model.sessions.count == 1 }
        let name = try XCTUnwrap(model.sessions.first?.name)
        defer { daemon.registry.kill(name: name) }
        await model.select(name)
        _ = ReviewFixture(model)
        model.setVimMode(false)
        model.focusPane(name)
        var received: [UInt8] = []
        model.setTerminalSink(for: name) { received += $0 }
        // Let the attach preamble land and drop it: it is full of escapes.
        try await Task.sleep(nanoseconds: 300_000_000)
        received = []

        await model.toggleReview()
        model.perform(.showLimitsDetail)
        XCTAssertEqual(model.inputMode, .limits, "precondition: the limits overlay is open over Review")
        XCTAssertEqual(model.focus, .terminal, "precondition: the hidden agent had the keyboard")
        model.applyReviewOverlayKey(KeyInput(isShift: true, special: .tab))
        model.applyReviewOverlayKey(KeyInput(isShift: true, special: .enter))
        XCTAssertEqual(model.inputMode, .limits, "a swallowed key leaves the overlay open")

        // `cat` writes its line back: once a marker sent after the keys
        // echoes, anything the keys sent (ESC [ Z, ESC CR) has come back too.
        try await Task.sleep(nanoseconds: 100_000_000)
        await model.sendInput(Array("marker\n".utf8), to: name)
        let echoed = await eventually { String(decoding: received, as: UTF8.self).contains("marker") }
        XCTAssertTrue(echoed, "precondition: the session echoes")
        XCTAssertFalse(received.contains(0x1b), "no key reached the hidden agent")

        model.applyReviewOverlayKey(KeyInput(special: .escape))
        XCTAssertEqual(model.inputMode, .normal, "Esc closes the overlay")
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
