import Foundation

/// A session the worktree picker may offer, in sidebar order.
struct ReviewWorktreeCandidate: Equatable {
    let session: String
    let dir: String
    let agent: String
    let projectRoot: String
}

/// One entry of the Review top bar's worktree picker.
struct ReviewWorktreeChoice: Equatable, Identifiable {
    /// The git toplevel.
    let worktree: String
    let projectRoot: String
    /// The first agent session working there: the send target of a new review.
    let session: String

    var id: String { worktree }
    var title: String { (worktree as NSString).lastPathComponent }
}

enum ReviewWorktrees {
    /// Distinct worktrees of the candidates, in candidate order. Shell
    /// sessions and directories with no toplevel (outside git) drop out.
    static func choices(_ candidates: [ReviewWorktreeCandidate],
                        toplevels: [String: String],
                        shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> [ReviewWorktreeChoice] {
        var seen: Set<String> = []
        var result: [ReviewWorktreeChoice] = []
        for candidate in candidates where !isShellAgent(candidate.agent, shell: shell) {
            guard let toplevel = toplevels[candidate.dir], seen.insert(toplevel).inserted else { continue }
            result.append(ReviewWorktreeChoice(worktree: toplevel, projectRoot: candidate.projectRoot,
                                               session: candidate.session))
        }
        return result
    }
}
