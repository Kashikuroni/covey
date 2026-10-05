import Foundation

extension Repository {
    public func requireClean() throws {
        let status = try git(["status", "--porcelain=v1", "--untracked-files=all"], readOnly: true)
        guard status.isEmpty else {
            throw GitError("working tree has uncommitted changes")
        }
    }

    public func isDirty() -> Bool {
        do {
            try requireClean()
            return false
        } catch {
            return true
        }
    }

    public func stashPush() throws {
        try git(["stash", "push", "--include-untracked", "-m", "covey-promote"])
    }

    public func stashPop() throws {
        try git(["stash", "pop"])
    }

    /// Branch (or short HEAD when detached) plus unstaged/staged numstat totals
    /// and the untracked-file count; nil outside a repository.
    public func workingTreeSummary() -> WorkingTreeSummary? {
        guard toplevel() != nil else { return nil }
        guard let branch = currentBranch() ?? shortHead() else { return nil }
        let unstaged = Numstat.totals((try? git(["diff", "--numstat", "-z"], readOnly: true)) ?? "")
        let staged = Numstat.totals(
            (try? git(["diff", "--cached", "--numstat", "-z"], readOnly: true)) ?? "")
        let untrackedOutput = (try? git(["ls-files", "--others", "--exclude-standard", "-z"],
                                        readOnly: true)) ?? ""
        let untracked = UInt32(clamping: untrackedOutput.split(
            separator: "\0", omittingEmptySubsequences: true).count)
        return WorkingTreeSummary(branch: branch, unstaged: unstaged, staged: staged,
                                  untracked: untracked)
    }
}
