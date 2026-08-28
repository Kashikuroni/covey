import Foundation
import CoveyKit

/// Blocking git plumbing for session creation (port of the needed slice of
/// amux-core git.rs). Every call shells out to `git -C`; callers keep these
/// off hot paths and outside registry locks.
public enum GitOps {
    public struct GitError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Runs `git -C dir args…`; returns trimmed stdout, throws on non-zero.
    /// `readOnly` adds GIT_OPTIONAL_LOCKS=0 (never stall on a locked index);
    /// every call forces LC_ALL=C so parsed English words are stable.
    @discardableResult
    static func run(_ dir: String, _ args: [String], readOnly: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(msg.isEmpty ? "git \(args.joined(separator: " ")) failed" : msg)
        }
        return String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func repoRoot(_ dir: String) -> String? {
        try? run(dir, ["rev-parse", "--show-toplevel"], readOnly: true)
    }

    public static func currentBranch(_ repo: String) -> String? {
        let b = try? run(repo, ["branch", "--show-current"], readOnly: true)
        return (b?.isEmpty ?? true) ? nil : b
    }

    public static func localBranches(_ repo: String) -> [String] {
        guard let out = try? run(repo, ["branch", "--list", "--format=%(refname:short)"],
                                 readOnly: true)
        else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public static func branchExists(_ repo: String, _ branch: String) -> Bool {
        (try? localBranchOID(repo, branch)) != nil
    }

    /// Returns the exact local branch tip, nil when absent, and throws when Git
    /// cannot answer. Full ref names avoid short-name ambiguity.
    static func localBranchOID(_ repo: String, _ branch: String) throws -> String? {
        let output = try run(
            repo,
            ["for-each-ref", "--format=%(refname)%09%(objectname)", "refs/heads"],
            readOnly: true
        )
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
    public static func isPrimaryWorktree(_ dir: String) throws -> Bool {
        let gitDir = try run(
            dir, ["rev-parse", "--path-format=absolute", "--git-dir"], readOnly: true
        )
        let commonDir = try run(
            dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            readOnly: true
        )
        return sameDirectory(gitDir, commonDir)
    }

    /// All of the repo's worktrees as branch -> path (porcelain parse). The
    /// main worktree is included; detached worktrees carry no branch line and
    /// are skipped.
    public static func worktrees(_ repo: String) -> [String: String] {
        (try? readWorktrees(repo)) ?? [:]
    }

    private static func readWorktrees(_ repo: String) throws -> [String: String] {
        let out = try run(repo, ["worktree", "list", "--porcelain"], readOnly: true)
        var map: [String: String] = [:]
        var path: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let p = path {
                map[String(line.dropFirst("branch refs/heads/".count))] = p
                path = nil
            }
        }
        return map
    }

    /// The worktree path where `branch` is checked out, if any.
    public static func worktreeForBranch(_ repo: String, _ branch: String) -> String? {
        worktrees(repo)[branch]
    }

    /// Appends `entry` to the repo's .gitignore unless already present.
    public static func ensureGitignore(_ repo: String, entry: String) throws {
        let path = "\(repo)/.gitignore"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(Substring(entry)) { return }
        var content = existing
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += entry + "\n"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Forks `newBranch` from `base` into a worktree at `wtPath`. Errors if the
    /// branch already exists; clears stale worktree state at the path first.
    public static func prepareWorktree(repo: String, wtPath: String,
                                       newBranch: String, base: String) throws {
        if branchExists(repo, newBranch) {
            throw GitError("branch '\(newBranch)' already exists — pick another name")
        }
        try clearStaleWorktreePath(repo: repo, wtPath: wtPath)
        try run(repo, ["worktree", "add", "-b", newBranch, wtPath, base])
    }

    /// prepareWorktree's twin for an EXISTING branch (no -b).
    public static func prepareWorktreeExisting(repo: String, wtPath: String,
                                               branch: String) throws {
        if !branchExists(repo, branch) {
            throw GitError("branch '\(branch)' does not exist")
        }
        try clearStaleWorktreePath(repo: repo, wtPath: wtPath)
        try run(repo, ["worktree", "add", wtPath, branch])
    }

    public static func removeWorktree(repo: String, wtPath: String) throws {
        try run(repo, ["worktree", "remove", "--force", wtPath])
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
    public static func seedWorktreeIgnored(repo: String, wtPath: String) {
        guard let out = try? run(repo, ["status", "--porcelain", "--ignored", "-z"],
                                 readOnly: true)
        else { return }
        let fm = FileManager.default
        for entry in out.split(separator: "\0", omittingEmptySubsequences: true) {
            guard entry.hasPrefix("!! ") else { continue }   // ignored entries only
            var rel = String(entry.dropFirst(3))
            if rel.hasSuffix("/") { rel.removeLast() }        // dir entries collapse to "path/"
            let first = rel.split(separator: "/").first.map(String.init) ?? rel
            if first == ".worktrees" || first == ".git" { continue }
            if heavyIgnoredDirs.contains((rel as NSString).lastPathComponent) { continue }
            let src = "\(repo)/\(rel)"
            let dst = "\(wtPath)/\(rel)"
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
    }

    /// Prunes vanished worktrees, then removes a non-empty orphan directory at
    /// the target path that git no longer tracks (an empty dir is left for git).
    private static func clearStaleWorktreePath(repo: String, wtPath: String) throws {
        _ = try? run(repo, ["worktree", "prune"])
        let nonEmpty = (try? FileManager.default.contentsOfDirectory(atPath: wtPath))
            .map { !$0.isEmpty } ?? false
        if nonEmpty, !isRegisteredWorktree(repo: repo, wtPath: wtPath) {
            try FileManager.default.removeItem(atPath: wtPath)
        }
    }

    private static func isRegisteredWorktree(repo: String, wtPath: String) -> Bool {
        guard let out = try? run(repo, ["worktree", "list", "--porcelain"], readOnly: true)
        else { return false }
        let canonical = URL(fileURLWithPath: wtPath).resolvingSymlinksInPath().path
        return out.split(separator: "\n").contains { line in
            guard line.hasPrefix("worktree ") else { return false }
            let p = String(line.dropFirst("worktree ".count))
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().path == canonical
        }
    }

    public static func requireCleanWorktree(_ dir: String) throws {
        let status = try run(
            dir, ["status", "--porcelain=v1", "--untracked-files=all"], readOnly: true
        )
        guard status.isEmpty else {
            throw GitError("working tree has uncommitted changes")
        }
    }

    public static func isDirty(_ dir: String) -> Bool {
        do {
            try requireCleanWorktree(dir)
            return false
        } catch {
            return true
        }
    }

    public static func stashPush(_ dir: String) throws {
        try run(dir, ["stash", "push", "--include-untracked", "-m", "covey-promote"])
    }

    public static func stashPop(_ dir: String) throws {
        try run(dir, ["stash", "pop"])
    }

    public static func checkout(repo: String, branch: String) throws {
        try run(repo, ["checkout", branch])
    }

    /// Creates `branch` from `base` and checks it out in the repo root.
    public static func createBranch(_ repo: String, _ branch: String, base: String) throws {
        try run(repo, ["checkout", "-b", branch, base])
    }

    /// Port of git.rs promote_worktree: stash dirty changes in the worktree,
    /// remove it, check the branch out in the repo root, pop the stash there
    /// (the stash lives in the shared .git). Errors short-circuit.
    public static func promoteWorktree(repo: String, wtDir: String, branch: String) throws {
        let dirty = isDirty(wtDir)
        if dirty { try stashPush(wtDir) }
        try run(repo, ["worktree", "remove", wtDir])
        try checkout(repo: repo, branch: branch)
        if dirty { try stashPop(repo) }
    }

    private static func requireDeletableBranch(_ branch: String) throws {
        if protectedBranches.contains(branch) {
            throw GitError("branch '\(branch)' is protected")
        }
    }

    public static func deleteBranch(repo: String, branch: String,
                                    force: Bool = false,
                                    expectedOID: String? = nil) throws {
        try requireDeletableBranch(branch)
        if force {
            guard try readWorktrees(repo)[branch] == nil else {
                throw GitError("branch '\(branch)' is checked out in a worktree")
            }
            guard let oid = try expectedOID ?? localBranchOID(repo, branch) else {
                throw GitError("branch '\(branch)' does not exist")
            }
            try run(repo, ["update-ref", "-d", "refs/heads/\(branch)", oid])
            try verifyDeletedBranchNotCheckedOut(
                repo: repo, branch: branch, expectedOID: oid
            )
        } else {
            try run(repo, ["branch", "-d", branch])
        }
        guard try localBranchOID(repo, branch) == nil else {
            throw GitError("branch '\(branch)' still exists after deletion")
        }
    }

    /// Compensates when a checkout wins the pre-delete scan race and publishes
    /// a symbolic worktree HEAD before the post-delete scan. Restore the
    /// captured tip before reporting the failed deletion; a failed scan also
    /// restores because occupancy could not be ruled out.
    static func verifyDeletedBranchNotCheckedOut(
        repo: String, branch: String, expectedOID: String
    ) throws {
        let checkedOutPath: String?
        do {
            checkedOutPath = try readWorktrees(repo)[branch]
        } catch {
            do {
                try restoreBranchIfAbsent(
                    repo: repo, branch: branch, expectedOID: expectedOID
                )
            } catch let restoreError {
                throw GitError(
                    "could not verify worktrees after deletion; restore failed: "
                        + "\(restoreError). Recover branch '\(branch)' at \(expectedOID)"
                )
            }
            throw GitError("could not verify worktrees after deletion; branch restored")
        }
        guard let checkedOutPath else { return }
        do {
            try restoreBranchIfAbsent(
                repo: repo, branch: branch, expectedOID: expectedOID
            )
        } catch let restoreError {
            throw GitError(
                "branch became checked out at '\(checkedOutPath)'; restore failed: "
                    + "\(restoreError). Recover branch '\(branch)' at \(expectedOID)"
            )
        }
        throw GitError(
            "branch became checked out at '\(checkedOutPath)' during deletion; branch restored"
        )
    }

    private static func restoreBranchIfAbsent(
        repo: String, branch: String, expectedOID: String
    ) throws {
        if try localBranchOID(repo, branch) != nil { return }
        do {
            try run(repo, ["update-ref", "refs/heads/\(branch)", expectedOID, ""])
        } catch {
            // A concurrent writer may have recreated the branch between the
            // read and conditional create. In that case it is no longer
            // dangling and must not be overwritten.
            if try localBranchOID(repo, branch) != nil { return }
            throw error
        }
    }

    public static func switchAndDeleteBranch(
        repo: String, expectedBranch: String, checkoutBranch: String
    ) throws {
        try requireDeletableBranch(expectedBranch)
        guard expectedBranch != checkoutBranch else {
            throw GitError("choose a different branch before deletion")
        }
        guard try localBranchOID(repo, checkoutBranch) != nil else {
            throw GitError("branch '\(checkoutBranch)' does not exist")
        }
        try requireCleanWorktree(repo)
        guard let current = currentBranch(repo),
              current == expectedBranch || current == checkoutBranch else {
            throw GitError("current branch changed; expected '\(expectedBranch)'")
        }
        if let path = worktreeForBranch(repo, checkoutBranch),
           !sameDirectory(path, repo) {
            throw GitError(
                "branch '\(checkoutBranch)' is checked out in another worktree"
            )
        }
        guard let sourceOID = try localBranchOID(repo, expectedBranch) else {
            if current == checkoutBranch { return }
            throw GitError("branch '\(expectedBranch)' does not exist")
        }
        if current == expectedBranch {
            try checkout(repo: repo, branch: checkoutBranch)
        }
        try deleteBranch(
            repo: repo,
            branch: expectedBranch,
            force: true,
            expectedOID: sourceOID
        )
    }

    private static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }

    /// Local branches fully merged into HEAD, excluding the current one.
    /// Protected branches are INCLUDED so callers can lock them in the UI.
    public static func listMergedBranches(_ repo: String) -> [String] {
        guard let out = try? run(repo, ["branch", "--merged", "HEAD",
                                        "--format=%(refname:short)"], readOnly: true)
        else { return [] }
        let current = currentBranch(repo) ?? ""
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && $0 != current }
    }

    /// Branch plus independent unstaged, staged, and untracked state.
    public static func readGitInfo(_ dir: String) -> GitInfo? {
        guard repoRoot(dir) != nil else { return nil }
        guard let branch = currentBranch(dir)
            ?? (try? run(dir, ["rev-parse", "--short", "HEAD"], readOnly: true))
        else { return nil }
        let unstaged = parseNumstat(
            (try? run(dir, ["diff", "--numstat", "-z"], readOnly: true)) ?? ""
        )
        let staged = parseNumstat(
            (try? run(dir, ["diff", "--cached", "--numstat", "-z"], readOnly: true)) ?? ""
        )
        let untrackedOutput = (
            try? run(dir, ["ls-files", "--others", "--exclude-standard", "-z"],
                     readOnly: true)
        ) ?? ""
        let untracked = UInt32(clamping: untrackedOutput.split(
            separator: "\0", omittingEmptySubsequences: true
        ).count)
        return GitInfo(
            branch: branch, unstaged: unstaged, staged: staged, untracked: untracked
        )
    }

    static func parseNumstat(_ output: String) -> GitDiffSummary {
        let limit = UInt64(UInt32.max)
        var files: UInt64 = 0
        var added: UInt64 = 0
        var removed: UInt64 = 0

        func add(_ value: UInt64, to total: inout UInt64) {
            total += min(value, limit - total)
        }

        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let fields = record.split(
                separator: "\t", maxSplits: 2, omittingEmptySubsequences: false
            )
            guard fields.count == 3 else { continue }
            add(1, to: &files)
            if let count = UInt64(fields[0]) { add(count, to: &added) }
            if let count = UInt64(fields[1]) { add(count, to: &removed) }
        }

        return GitDiffSummary(
            files: UInt32(files), added: UInt32(added), removed: UInt32(removed)
        )
    }

    /// Resolves the first word of `cmd` on PATH via `command -v`. The word is
    /// passed as $0, never interpolated into shell code (no injection).
    public static func resolveAgentPath(_ cmd: String) -> String? {
        guard let bin = cmd.split(separator: " ").first.map(String.init), !bin.isEmpty
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "command -v -- \"$0\"", bin]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
