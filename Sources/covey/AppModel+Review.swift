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
            leaveReview()
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
        review = created
        windowMode = .review
        syncReviewVisibility()
        await created.start()
    }

    /// Back to the sessions. The review keeps its state and stops polling.
    func leaveReview() {
        reviewEntryGeneration += 1
        guard windowMode == .review else { return }
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

    /// Entering Review looks for the agent's changes at once.
    private func show(_ review: ReviewModel) async {
        windowMode = .review
        syncReviewVisibility()
        await review.checkFreshness()
    }

    // Kept for the Review window until the main window hosts Review (Task 6).
    func reviewLaunch(for key: ReviewWindowKey) -> ReviewLaunch? { reviewLaunches[key] }

    func consumeReviewWindowRequest() { reviewWindowRequest = nil }
}
