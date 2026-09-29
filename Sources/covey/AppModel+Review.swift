import Foundation
import CoveyGit
import CoveyKit

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
    /// Resolves the focused session's worktree toplevel off the main thread,
    /// remembers who asked, and raises `reviewWindowRequest`.
    func openReviewForSelected() {
        guard let name = selected, let session = sessions.first(where: { $0.name == name }) else { return }
        let dir = session.dir
        let launch = ReviewLaunch(originSession: session.name, projectRoot: sessionRoot(session))
        Task { [weak self] in
            let toplevel = await Task.detached { Repository(at: dir).toplevel() }.value
            guard let self else { return }
            guard let toplevel else {
                self.showToast("Not a Git repository: \(dir)")
                return
            }
            let key = ReviewWindowKey(worktree: toplevel)
            self.reviewLaunches[key] = launch
            self.reviewWindowRequest = key
        }
    }

    func reviewLaunch(for key: ReviewWindowKey) -> ReviewLaunch? { reviewLaunches[key] }

    func consumeReviewWindowRequest() { reviewWindowRequest = nil }
}
