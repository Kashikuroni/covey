import Foundation

extension Repository {
    /// `rev-parse --show-toplevel`: the root of the worktree containing `path`;
    /// nil outside a repository.
    public func toplevel() -> String? {
        try? git(["rev-parse", "--show-toplevel"], readOnly: true)
    }

    public func currentBranch() -> String? {
        let branch = try? git(["branch", "--show-current"], readOnly: true)
        return (branch?.isEmpty ?? true) ? nil : branch
    }

    /// Abbreviated HEAD commit — the label for a detached HEAD.
    public func shortHead() -> String? {
        try? git(["rev-parse", "--short", "HEAD"], readOnly: true)
    }

    public func localBranches() -> [String] {
        guard let out = try? git(["branch", "--list", "--format=%(refname:short)"],
                                 readOnly: true)
        else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func branchExists(_ branch: String) -> Bool {
        (try? localBranchOID(branch)) != nil
    }

    /// The exact local branch tip, nil when absent; throws when git cannot
    /// answer. Full ref names avoid short-name ambiguity.
    public func localBranchOID(_ branch: String) throws -> String? {
        let output = try git(["for-each-ref", "--format=%(refname)%09%(objectname)", "refs/heads"],
                             readOnly: true)
        let target = "refs/heads/\(branch)"
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            if fields.count == 2, fields[0] == target {
                return String(fields[1])
            }
        }
        return nil
    }

    /// True only for the repository's primary worktree. Git failures throw so
    /// destructive callers can reject unknown layouts instead of guessing.
    public func isPrimaryWorktree() throws -> Bool {
        let gitDir = try git(["rev-parse", "--path-format=absolute", "--git-dir"], readOnly: true)
        let commonDir = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"],
                                readOnly: true)
        return Self.sameDirectory(gitDir, commonDir)
    }
}
