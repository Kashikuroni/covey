import Foundation

extension Repository {
    public func checkout(_ branch: String) throws {
        try git(["checkout", branch])
    }

    /// Creates `branch` from `base` and checks it out here.
    public func createBranch(_ branch: String, from base: String) throws {
        try git(["checkout", "-b", branch, base])
    }

    private func requireDeletable(_ branch: String, protected: [String]) throws {
        if protected.contains(branch) {
            throw GitError("branch '\(branch)' is protected")
        }
    }

    /// Safe mode is `branch -d` (merged only). Force mode deletes the exact tip
    /// (`expectedOID`, or the current one) with `update-ref -d`, refuses a
    /// branch checked out in any worktree, and restores the tip if a checkout
    /// races the deletion.
    public func deleteBranch(_ branch: String, force: Bool = false,
                             expectedOID: String? = nil, protected: [String]) throws {
        try requireDeletable(branch, protected: protected)
        if force {
            guard try readWorktrees()[branch] == nil else {
                throw GitError("branch '\(branch)' is checked out in a worktree")
            }
            guard let oid = try expectedOID ?? localBranchOID(branch) else {
                throw GitError("branch '\(branch)' does not exist")
            }
            try git(["update-ref", "-d", "refs/heads/\(branch)", oid])
            try verifyDeletedBranchNotCheckedOut(branch: branch, expectedOID: oid)
        } else {
            try git(["branch", "-d", branch])
        }
        guard try localBranchOID(branch) == nil else {
            throw GitError("branch '\(branch)' still exists after deletion")
        }
    }

    /// Compensates when a checkout wins the pre-delete scan race and publishes
    /// a symbolic worktree HEAD before the post-delete scan. Restore the
    /// captured tip before reporting the failed deletion; a failed scan also
    /// restores because occupancy could not be ruled out.
    func verifyDeletedBranchNotCheckedOut(branch: String, expectedOID: String) throws {
        let checkedOutPath: String?
        do {
            checkedOutPath = try readWorktrees()[branch]
        } catch {
            do {
                try restoreBranchIfAbsent(branch, expectedOID: expectedOID)
            } catch let restoreError {
                throw GitError(
                    "could not verify worktrees after deletion; restore failed: "
                        + "\(restoreError). Recover branch '\(branch)' at \(expectedOID)")
            }
            throw GitError("could not verify worktrees after deletion; branch restored")
        }
        guard let checkedOutPath else { return }
        do {
            try restoreBranchIfAbsent(branch, expectedOID: expectedOID)
        } catch let restoreError {
            throw GitError(
                "branch became checked out at '\(checkedOutPath)'; restore failed: "
                    + "\(restoreError). Recover branch '\(branch)' at \(expectedOID)")
        }
        throw GitError(
            "branch became checked out at '\(checkedOutPath)' during deletion; branch restored")
    }

    private func restoreBranchIfAbsent(_ branch: String, expectedOID: String) throws {
        if try localBranchOID(branch) != nil { return }
        do {
            try git(["update-ref", "refs/heads/\(branch)", expectedOID, ""])
        } catch {
            // A concurrent writer may have recreated the branch between the
            // read and conditional create. In that case it is no longer
            // dangling and must not be overwritten.
            if try localBranchOID(branch) != nil { return }
            throw error
        }
    }

    /// Leaves `expected` for `checkout` in this (primary) checkout, then
    /// force-deletes `expected` at the tip seen before the switch. Retry-safe:
    /// a second call after the checkout already happened still deletes.
    public func switchAndDeleteBranch(expected: String, checkout target: String,
                                      protected: [String]) throws {
        try requireDeletable(expected, protected: protected)
        guard expected != target else {
            throw GitError("choose a different branch before deletion")
        }
        guard try localBranchOID(target) != nil else {
            throw GitError("branch '\(target)' does not exist")
        }
        try requireClean()
        guard let current = currentBranch(), current == expected || current == target else {
            throw GitError("current branch changed; expected '\(expected)'")
        }
        if let other = worktreePath(forBranch: target), !Self.sameDirectory(other, path) {
            throw GitError("branch '\(target)' is checked out in another worktree")
        }
        guard let sourceOID = try localBranchOID(expected) else {
            if current == target { return }
            throw GitError("branch '\(expected)' does not exist")
        }
        if current == expected {
            try checkout(target)
        }
        try deleteBranch(expected, force: true, expectedOID: sourceOID, protected: protected)
    }

    /// Local branches fully merged into HEAD, excluding the current one.
    /// Protected branches are INCLUDED so callers can lock them in the UI.
    public func mergedBranches() -> [String] {
        guard let out = try? git(["branch", "--merged", "HEAD", "--format=%(refname:short)"],
                                 readOnly: true)
        else { return [] }
        let current = currentBranch() ?? ""
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && $0 != current }
    }
}
