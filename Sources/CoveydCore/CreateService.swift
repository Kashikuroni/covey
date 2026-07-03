import Foundation
import CoveyKit

/// IO orchestration of session creation (port of create.rs create_session):
/// composes the launch command via CreateLogic, resolves the agent binary,
/// forks a git worktree when requested, and yields everything the registry
/// needs to spawn. No registry locks are held while this runs.
public enum CreateService {
    public struct Prepared: Equatable {
        public var finalDir: String
        public var argv: [String]
        public var label: String
        public var worktreeRepo: String?
        public var resumeCmd: String?
    }

    public static func prepare(_ spec: CreateSpec) throws -> Prepared {
        // UUID only for a plain, non-terminal, non-resume claude launch.
        let uuid: String? = (!spec.terminal && spec.resume == nil && spec.agent == "claude")
            ? UUID().uuidString.lowercased() : nil
        let (command, label, resumeCmd) = composeLaunch(spec: spec, uuid: uuid)

        let argv: [String]
        if spec.terminal {
            argv = [command]
        } else {
            // Resolve the first word to an absolute path (the daemon's PATH may
            // be narrower than the shell that configured the agent).
            argv = ["/bin/sh", "-c", resolveCommand(command)]
        }

        guard let wt = spec.worktree else {
            return Prepared(finalDir: spec.dir, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        }
        guard let repo = GitOps.repoRoot(spec.dir) else {
            throw GitOps.GitError("not a git repo: \(spec.dir)")
        }
        let wtFor = { (branch: String) in "\(repo)/.worktrees/\(branch)" }

        switch wt {
        case .new(let branch, let base):
            if let err = validateBranch(branch) { throw GitOps.GitError(err) }
            try GitOps.ensureGitignore(repo, entry: ".worktrees/")
            let path = wtFor(branch)
            try GitOps.prepareWorktree(repo: repo, wtPath: path, newBranch: branch, base: base)
            return Prepared(finalDir: path, argv: argv, label: label,
                            worktreeRepo: repo, resumeCmd: resumeCmd)
        case .existing(let branch):
            if let p = checkedOutPrepared(repo: repo, branch: branch, argv: argv,
                                          label: label, resumeCmd: resumeCmd) {
                return p
            }
            try GitOps.ensureGitignore(repo, entry: ".worktrees/")
            let path = wtFor(branch)
            try GitOps.prepareWorktreeExisting(repo: repo, wtPath: path, branch: branch)
            return Prepared(finalDir: path, argv: argv, label: label,
                            worktreeRepo: repo, resumeCmd: resumeCmd)
        case .checkout(let branch):
            if let p = checkedOutPrepared(repo: repo, branch: branch, argv: argv,
                                          label: label, resumeCmd: resumeCmd) {
                return p
            }
            try GitOps.checkout(repo: repo, branch: branch)
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        case .checkoutNew(let branch, let base):
            if let err = validateBranch(branch) { throw GitOps.GitError(err) }
            try GitOps.createBranch(repo, branch, base: base)
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        }
    }

    /// Where `branch` is already checked out, the session opens there: the
    /// repo's main worktree makes a plain session; a linked worktree makes a
    /// removable worktree session.
    private static func checkedOutPrepared(repo: String, branch: String, argv: [String],
                                           label: String, resumeCmd: String?) -> Prepared? {
        guard let path = GitOps.worktreeForBranch(repo, branch) else { return nil }
        if sameDir(path, repo) {
            return Prepared(finalDir: repo, argv: argv, label: label,
                            worktreeRepo: nil, resumeCmd: resumeCmd)
        }
        return Prepared(finalDir: path, argv: argv, label: label,
                        worktreeRepo: repo, resumeCmd: resumeCmd)
    }

    private static func resolveCommand(_ command: String) -> String {
        guard let bin = command.split(separator: " ").first.map(String.init),
              !bin.contains("/"),
              let path = GitOps.resolveAgentPath(bin)
        else { return command }
        return path + command.dropFirst(bin.count)
    }

    private static func sameDir(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }
}
