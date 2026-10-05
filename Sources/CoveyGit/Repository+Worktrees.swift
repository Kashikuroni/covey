import Foundation

extension Repository {
    /// All of the repo's worktrees as branch -> path (porcelain parse). The
    /// main worktree is included; detached worktrees carry no branch line and
    /// are skipped.
    public func worktrees() -> [String: String] {
        (try? readWorktrees()) ?? [:]
    }

    func readWorktrees() throws -> [String: String] {
        let out = try git(["worktree", "list", "--porcelain"], readOnly: true)
        var map: [String: String] = [:]
        var current: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                current = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let p = current {
                map[String(line.dropFirst("branch refs/heads/".count))] = p
                current = nil
            }
        }
        return map
    }

    /// The worktree path where `branch` is checked out, if any.
    public func worktreePath(forBranch branch: String) -> String? {
        worktrees()[branch]
    }

    /// Appends `entry` to the repo's .gitignore unless already present.
    public func ensureGitignore(entry: String) throws {
        let file = "\(path)/.gitignore"
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(Substring(entry)) { return }
        var content = existing
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += entry + "\n"
        try content.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Forks `newBranch` from `base` into a worktree at `wtPath`. Errors if the
    /// branch already exists; clears stale worktree state at the path first.
    public func addWorktree(at wtPath: String, newBranch: String, base: String) throws {
        if branchExists(newBranch) {
            throw GitError("branch '\(newBranch)' already exists — pick another name")
        }
        try clearStaleWorktreePath(wtPath)
        try git(["worktree", "add", "-b", newBranch, wtPath, base])
    }

    /// The twin of `addWorktree(at:newBranch:base:)` for an EXISTING branch.
    public func addWorktree(at wtPath: String, existingBranch branch: String) throws {
        if !branchExists(branch) {
            throw GitError("branch '\(branch)' does not exist")
        }
        try clearStaleWorktreePath(wtPath)
        try git(["worktree", "add", wtPath, branch])
    }

    public func removeWorktree(at wtPath: String) throws {
        try git(["worktree", "remove", "--force", wtPath])
    }

    /// Regenerable dep/build directories never worth copying into a new
    /// worktree (matched by basename). Everything else that git ignores is
    /// seeded so the fresh tree can build.
    public static let heavyIgnoredDirs: Set<String> = [
        "node_modules", ".build", "build", "dist", "out", "target", ".next",
        ".venv", "venv", "__pycache__", ".gradle", "DerivedData", "Pods",
        ".turbo", ".cache", "coverage",
    ]

    /// Copies the repo's gitignored files into a freshly-added worktree so it
    /// carries the build-critical files git left behind (.env, local configs).
    /// Best-effort: enumeration or per-entry copy failures are swallowed — a
    /// seeding hiccup must never abort session creation. Fully-ignored
    /// directories are copied whole; `heavyIgnoredDirs` and covey's own
    /// `.worktrees/`/`.git` are skipped.
    public func seedIgnoredFiles(into wtPath: String) {
        guard let out = try? git(["status", "--porcelain", "--ignored", "-z"], readOnly: true)
        else { return }
        let fm = FileManager.default
        for entry in out.split(separator: "\0", omittingEmptySubsequences: true) {
            guard entry.hasPrefix("!! ") else { continue }   // ignored entries only
            var rel = String(entry.dropFirst(3))
            if rel.hasSuffix("/") { rel.removeLast() }        // dir entries collapse to "path/"
            let first = rel.split(separator: "/").first.map(String.init) ?? rel
            if first == ".worktrees" || first == ".git" { continue }
            if Self.heavyIgnoredDirs.contains((rel as NSString).lastPathComponent) { continue }
            let src = "\(path)/\(rel)"
            let dst = "\(wtPath)/\(rel)"
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
    }

    /// Stash dirty changes in the worktree at `wtDir`, remove it, check the
    /// branch out in this (root) checkout, pop the stash here (the stash lives
    /// in the shared .git). Errors short-circuit.
    public func promoteWorktree(at wtDir: String, branch: String) throws {
        let worktree = Repository(at: wtDir)
        let dirty = worktree.isDirty()
        if dirty { try worktree.stashPush() }
        try git(["worktree", "remove", wtDir])
        try checkout(branch)
        if dirty { try stashPop() }
    }

    /// Prunes vanished worktrees, then removes a non-empty orphan directory at
    /// the target path that git no longer tracks (an empty dir is left for git).
    private func clearStaleWorktreePath(_ wtPath: String) throws {
        _ = try? git(["worktree", "prune"])
        let nonEmpty = (try? FileManager.default.contentsOfDirectory(atPath: wtPath))
            .map { !$0.isEmpty } ?? false
        if nonEmpty, !isRegisteredWorktree(wtPath) {
            try FileManager.default.removeItem(atPath: wtPath)
        }
    }

    private func isRegisteredWorktree(_ wtPath: String) -> Bool {
        guard let out = try? git(["worktree", "list", "--porcelain"], readOnly: true)
        else { return false }
        let canonical = URL(fileURLWithPath: wtPath).resolvingSymlinksInPath().path
        return out.split(separator: "\n").contains { line in
            guard line.hasPrefix("worktree ") else { return false }
            let p = String(line.dropFirst("worktree ".count))
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().path == canonical
        }
    }
}
