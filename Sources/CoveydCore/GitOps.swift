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
        (try? run(repo, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                  readOnly: true)) != nil
    }

    /// All of the repo's worktrees as branch -> path (porcelain parse). The
    /// main worktree is included; detached worktrees carry no branch line and
    /// are skipped.
    public static func worktrees(_ repo: String) -> [String: String] {
        guard let out = try? run(repo, ["worktree", "list", "--porcelain"], readOnly: true)
        else { return [:] }
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

    public static func isDirty(_ dir: String) -> Bool {
        !((try? run(dir, ["status", "--porcelain"], readOnly: true)) ?? "").isEmpty
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

    public static func deleteBranch(repo: String, branch: String) throws {
        try run(repo, ["branch", "-d", branch])
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

    /// Branch + working-tree shortstat, or nil outside a repo (git.rs read()).
    public static func readGitInfo(_ dir: String) -> GitInfo? {
        guard repoRoot(dir) != nil else { return nil }
        guard let branch = currentBranch(dir)
            ?? (try? run(dir, ["rev-parse", "--short", "HEAD"], readOnly: true))
        else { return nil }
        let stat = (try? run(dir, ["diff", "--shortstat"], readOnly: true)) ?? ""
        let (added, removed) = parseShortstat(stat)
        return GitInfo(branch: branch, added: UInt32(added), removed: UInt32(removed))
    }

    public static func parseShortstat(_ s: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let n = p.split(separator: " ").first.flatMap({ Int($0) }) else { continue }
            if p.contains("insertion") { added = n }
            else if p.contains("deletion") { removed = n }
        }
        return (added, removed)
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
