import Foundation

extension Repository {
    /// Updates the current branch from `base`: fast-forward when possible
    /// (already-up-to-date counts), else a merge commit. On conflict the
    /// merge is aborted immediately — the repository is never left in a
    /// conflict state — and git's message surfaces as the refusal.
    @discardableResult
    public func updateFromBase(base: String) throws -> Bool {
        guard currentBranch() != nil else {
            throw GitError("detached HEAD — switch to a branch before updating")
        }
        guard resolveCommit(base) != nil else {
            throw GitError("unknown revision '\(base)'")
        }
        try requireClean()

        let ff = try GitRunner.execute(in: path, ["merge", "--ff-only", base], readOnly: false)
        if ff.status == 0 { return true }

        // Diverged: a real merge; any failure aborts itself.
        let merge = try GitRunner.execute(in: path, ["merge", base, "--no-edit"], readOnly: false)
        if merge.status == 0 { return false }
        _ = try? GitRunner.run(in: path, ["merge", "--abort"])
        let message = merge.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitError(kind: .failed(status: merge.status),
                       description: message.isEmpty ? "merge from '\(base)' failed" : message)
    }
}
