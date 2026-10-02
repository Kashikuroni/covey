import Foundation
import CoveyGit
import CoveyKit

/// What the main window shows (Review spec, part 1).
enum WindowMode: Equatable {
    case sessions, review
}

/// Who a review is for: the worktree toplevel, the project whose sessions
/// may receive it, and the default send target.
struct ReviewOpening: Equatable {
    let worktree: String
    let projectRoot: String
    let originSession: String?
}

extension AppModel: ReviewSessionDirectory {
    func reviewTargets(projectRoot: String) -> [ReviewTarget] {
        visibleSessions
            .filter { sessionRoot($0) == projectRoot && !isShellAgent($0.agent) }
            .map { ReviewTarget(name: $0.name, dir: $0.dir, agent: $0.agent,
                                status: statusByName[$0.name] ?? .idle) }
    }

    func sendToSession(_ name: String, bytes: [UInt8]) async throws {
        try await client.input(name: name, bytes: bytes)
    }

    func didSendReview(to name: String) {
        pendingWatchSession = name
    }
}

extension AppModel {
    /// The production `resolveReviewWorktree`: git's toplevel, off the main thread.
    nonisolated static func gitToplevel(_ dir: String) async -> String? {
        await Task.detached { Repository(at: dir).toplevel() }.value
    }

    /// ⌥⌘R, the menu toggle and the top bar switch. From Review: back to the
    /// sessions, the review stays alive. From the sessions: the selected
    /// session's worktree — or, with nothing selected, the live review.
    func toggleReview() async {
        if windowMode == .review {
            await leaveReview()
            return
        }
        guard let name = selected, let session = sessions.first(where: { $0.name == name }) else {
            if let review { await show(review) }
            return
        }
        await enterReview(dir: session.dir, projectRoot: sessionRoot(session), origin: session.name)
    }

    /// Resolves `dir`'s worktree toplevel, then opens Review for it. A newer
    /// entry — or leaving Review — while git answers drops this one.
    func enterReview(dir: String, projectRoot: String, origin: String?) async {
        reviewEntryGeneration += 1
        let generation = reviewEntryGeneration
        let toplevel = await resolveReviewWorktree(dir)
        guard generation == reviewEntryGeneration else { return }
        guard let toplevel else {
            showToast("Not a Git repository: \(dir)")
            return
        }
        await openReview(ReviewOpening(worktree: toplevel, projectRoot: projectRoot, originSession: origin))
    }

    /// Shows Review for `opening.worktree`: the live review when it is for
    /// that worktree (comments, marks and drafts intact), otherwise a new one
    /// once the old one is flushed to disk.
    func openReview(_ opening: ReviewOpening) async {
        reviewEntryGeneration += 1
        if let review, review.worktree == opening.worktree {
            await show(review)
            return
        }
        review?.flush()
        let created = reviewModelFactory?(opening) ?? ReviewModel(
            worktree: opening.worktree, projectRoot: opening.projectRoot,
            originSession: opening.originSession,
            git: ReviewGitService(), store: .shared, directory: self)
        created.linkSettings = reviewLinks
        review = created
        windowMode = .review
        syncReviewVisibility()
        await created.start()
    }

    /// Back to the sessions. The review keeps its state and stops polling.
    /// After a send the session it went to is selected first — once, and
    /// only while it is still a visible session — so "⌥⌘R to watch" shows
    /// that agent; its pane swaps in while still parked.
    func leaveReview() async {
        reviewEntryGeneration += 1
        guard windowMode == .review else { return }
        if let name = pendingWatchSession {
            pendingWatchSession = nil
            if visibleSessions.contains(where: { $0.name == name }) {
                await select(name)
                // Another trip back finished while the selection attached.
                guard windowMode == .review else { return }
            }
        }
        windowMode = .sessions
        syncReviewVisibility()
        review?.flush()
    }

    /// The main window's occlusion, reported by `ContentView`.
    func setMainWindowOccluded(_ occluded: Bool) {
        mainWindowOccluded = occluded
        syncReviewVisibility()
    }

    /// The review polls git only while it is on screen.
    func syncReviewVisibility() {
        review?.isVisible = windowMode == .review && !mainWindowOccluded
    }

    /// Worktrees the Review top bar offers: those of the visible agent
    /// sessions, in sidebar order, each resolved off the main thread.
    func reviewWorktreeChoices() async -> [ReviewWorktreeChoice] {
        let candidates = orderedSessions().flatMap(\.sessions)
            .filter { !isShellAgent($0.agent) }
            .map { ReviewWorktreeCandidate(session: $0.name, dir: $0.dir, agent: $0.agent,
                                           projectRoot: sessionRoot($0)) }
        var toplevels: [String: String] = [:]
        for dir in Set(candidates.map(\.dir)) {
            toplevels[dir] = await resolveReviewWorktree(dir)
        }
        return ReviewWorktrees.choices(candidates, toplevels: toplevels)
    }

    /// The Review top bar's worktree picker: ⌥⌘R for `choice`. Its session
    /// becomes the selection too — the pane behind Review swaps while parked,
    /// a selection change, not a mode switch — so ⌥⌘R back and forth comes
    /// back to the picked review. Leaving Review meanwhile drops the pick.
    func pickReviewWorktree(_ choice: ReviewWorktreeChoice) async {
        reviewEntryGeneration += 1
        let generation = reviewEntryGeneration
        if visibleSessions.contains(where: { $0.name == choice.session }) {
            await select(choice.session)
        }
        guard generation == reviewEntryGeneration else { return }
        await openReview(ReviewOpening(worktree: choice.worktree, projectRoot: choice.projectRoot,
                                       originSession: choice.session))
    }

    /// A key while a main-window overlay (limits, help) is open over Review:
    /// only the overlay's own actions run (`ReviewModeKeys.overlayAction`).
    func applyReviewOverlayKey(_ key: KeyInput) {
        let context = KeyRouter.Context(mode: inputMode, focus: focus, vimMode: vimMode,
                                        sheetOpen: modal != nil)
        if let action = ReviewModeKeys.overlayAction(key, context: context) { apply(action) }
    }

    /// Entering Review looks for the agent's changes at once. A review whose
    /// worktree is gone — or is back after it was gone — starts over instead:
    /// `start()` lands in `.missingWorktree` or loads it again. It is an
    /// entry of its own, so a toplevel still on its way for an earlier one
    /// cannot replace the review just shown.
    private func show(_ review: ReviewModel) async {
        reviewEntryGeneration += 1
        windowMode = .review
        syncReviewVisibility()
        if review.phase == .missingWorktree || review.worktreeIsGone {
            await review.start()
        } else {
            await review.checkFreshness()
        }
    }
}
