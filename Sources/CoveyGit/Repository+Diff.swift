import Foundation

/// Read-only comparison API for the Review window. Every method expects
/// `path` to be a worktree TOPLEVEL: git prints paths relative to it.
extension Repository {
    public static let diffTimeout: TimeInterval = 10
    public static let diffOutputLimit = 32 << 20
    /// Untracked files above this size are listed without line counts and
    /// never read.
    public static let untrackedCountLimit: Int64 = 8 << 20

    /// The commit `ref` names, or nil. Refuses option-shaped input outright.
    /// Nil also covers a git failure or timeout; `requireCommit` tells them apart.
    public func resolveCommit(_ ref: String) -> String? {
        (try? lookupCommit(ref)) ?? nil
    }

    public func mergeBase(_ a: String, _ b: String) -> String? {
        (try? lookupMergeBase(a, b)) ?? nil
    }

    /// `main` → `master` → the branch `origin/HEAD` points at → nil. Not the
    /// current branch's upstream: an agent branch's upstream is its own
    /// remote copy, which would hide the branch's work.
    public func defaultBase() -> String? {
        for candidate in ["main", "master"] where branchExists(candidate) { return candidate }
        // `origin/HEAD` can dangle (its target branch was deleted); only a target
        // that still resolves to a commit is a base.
        if let out = try? GitRunner.execute(in: path, ["symbolic-ref", "--quiet", "--short",
                                                        "refs/remotes/origin/HEAD"],
                                            readOnly: true, timeout: Self.diffTimeout),
           out.status == 0 {
            let remote = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remote.isEmpty, resolveCommit(remote) != nil { return remote }
        }
        return nil
    }

    public func changes(in comparison: GitComparison) throws -> ComparisonState {
        try changes(in: comparison, afterListing: nil)
    }

    /// One load of a comparison, read in a fixed window so an edit that lands
    /// mid-load can never be baked into the returned fingerprint:
    ///
    /// 1. `status0`, before any listing read.
    /// 2. The path listing: name-status (+ ls-files for the working tree).
    /// 3. `stamps1` of the listed paths, then `status1`; `afterListing` runs here.
    /// 4. Content reads: numstat, untracked line counting.
    /// 5. `stamps2`, then `status2`.
    ///
    /// If the status text or the stamps moved anywhere in the window the
    /// fingerprint is `unstable:<uuid>`, which no poll ever reproduces, so the
    /// next poll reloads. Otherwise it is exactly what `fingerprint(of:paths:)`
    /// builds now, so an idle view compares equal. Ref…ref has no window.
    /// `afterListing` is a test seam that injects an edit at step 3.
    func changes(in comparison: GitComparison, afterListing: (() -> Void)?) throws -> ComparisonState {
        let base = try requireCommit(comparison.base)
        let headRev = try headRevision(comparison)
        guard let mergeBase = try lookupMergeBase(base, headRev) else {
            throw GitError(kind: .unknownRef(comparison.base),
                           description: "'\(comparison.base)' shares no history with \(headRev)")
        }
        let range = rangeArgs(comparison, mergeBase: mergeBase, headRev: headRev)
        var isWorkingTree = false
        if case .workingTree = comparison.head { isWorkingTree = true }

        // 1
        let status0 = isWorkingTree ? try statusSnapshot() : ""
        // 2
        let entries = NameStatus.parse(
            try read(Self.diffArgs(["--no-color", "--no-ext-diff", "--name-status", "-z", "-M"]
                                   + range + ["--"])))
        var untrackedPaths: [String] = []
        if isWorkingTree {
            let listed = Set(entries.map(\.path))
            let untracked = try read(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"])
            untrackedPaths = untracked.split(separator: "\0").map(String.init).filter { !listed.contains($0) }
        }
        let paths = (entries.map(\.path) + untrackedPaths).sorted()
        // 3
        let stamps1 = isWorkingTree ? stamps(of: paths) : [:]
        let status1 = isWorkingTree ? try statusSnapshot() : ""
        afterListing?()
        // 4
        let counts = Numstat.byPath(
            try read(Self.diffArgs(["--no-color", "--no-ext-diff", "--numstat", "-z", "-M"]
                                   + range + ["--"])))
        var files = entries.map { entry -> ChangedFile in
            let c = counts[entry.path]
            return ChangedFile(path: entry.path, oldPath: entry.oldPath,
                               status: NameStatus.status(for: entry.code),
                               added: c?.added, removed: c?.removed,
                               isBinary: c.map { $0.added == nil && $0.removed == nil } ?? false)
        }
        files += untrackedPaths.map(untrackedFile)
        files.sort { $0.path < $1.path }
        // 5
        guard isWorkingTree else {
            return ComparisonState(mergeBase: mergeBase, files: files, stamps: [:],
                                   fingerprint: "ref:\(base):\(headRev)")
        }
        let stamps2 = stamps(of: paths)
        let status2 = try statusSnapshot()
        let moved = status0 != status1 || status1 != status2 || stamps1 != stamps2
        let fingerprint = moved
            ? "unstable:\(UUID().uuidString)"
            : workingTreeFingerprint(base: base, headRev: headRev, status: status2,
                                     paths: paths, stamps: stamps2)
        return ComparisonState(mergeBase: mergeBase, files: files, stamps: stamps2,
                               fingerprint: fingerprint)
    }

    /// Cheap "did anything change?" token. Working tree: base + HEAD commits,
    /// `status --porcelain=v2` (index-cached, so fast) and mtime/size of the
    /// already-changed `paths` — edits to files that were already dirty do not
    /// show in status. Ref…ref: the two resolved commits.
    public func fingerprint(of comparison: GitComparison, paths: [String]) throws -> String {
        let base = try requireCommit(comparison.base)
        let headRev = try headRevision(comparison)
        guard case .workingTree = comparison.head else { return "ref:\(base):\(headRev)" }
        let stamps = stamps(of: paths)
        let status = try statusSnapshot()
        return workingTreeFingerprint(base: base, headRev: headRev, status: status,
                                      paths: paths, stamps: stamps)
    }

    public func diff(of file: ChangedFile, in comparison: GitComparison, mergeBase: String,
                     fullFile: Bool = false) throws -> FileDiff {
        // `mergeBase` (normally `ComparisonState.mergeBase`, an object id) sits
        // before the `--` separator, so an option-shaped value must not reach git.
        guard !mergeBase.hasPrefix("-") else {
            throw GitError(kind: .unknownRef(mergeBase), description: "unknown revision '\(mergeBase)'")
        }
        var args = Self.diffArgs(["--no-color", "--no-ext-diff"])
        if fullFile { args.append("--unified=1000000") }
        if file.isUntracked {
            args += ["--no-index", "--", "/dev/null", file.path]
            let out = try GitRunner.execute(in: path, args, readOnly: true,
                                            timeout: Self.diffTimeout, outputLimit: Self.diffOutputLimit)
            // `--no-index` exits 1 when the files differ, but real errors (a vanished
            // file, a nested repository, a symlink to a directory) exit 1 too, with
            // nothing on stdout: only a printed diff makes exit 1 a success.
            guard out.status == 0 || (out.status == 1 && !out.stdout.isEmpty) else {
                throw failure(args, out)
            }
            return UnifiedDiff.parse(out.stdout)
        }
        args += ["-M", mergeBase]
        if case .ref(let ref) = comparison.head { args.append(try requireCommit(ref)) }
        args.append("--")
        if let old = file.oldPath { args.append(old) }
        args.append(file.path)
        return UnifiedDiff.parse(try read(args))
    }

    // MARK: - private

    /// `git diff` with `diff.suppressBlankEmpty` forced off: a user's `true` makes git
    /// print a blank context line as a bare "\n", which line numbering must not depend on.
    private static func diffArgs(_ args: [String]) -> [String] {
        ["-c", "diff.suppressBlankEmpty=false", "diff"] + args
    }

    /// The commit `ref` names; nil when git ran and it does not resolve. Throws
    /// only when git itself could not answer (launch failure, timeout, output cap).
    private func lookupCommit(_ ref: String) throws -> String? {
        guard !ref.isEmpty, !ref.hasPrefix("-") else { return nil }
        let out = try GitRunner.execute(in: path, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
                                        readOnly: true, timeout: Self.diffTimeout)
        guard out.status == 0 else { return nil }
        let oid = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// The merge base of `a` and `b`; nil when git ran and found none. Throws only
    /// when git itself could not answer.
    private func lookupMergeBase(_ a: String, _ b: String) throws -> String? {
        let out = try GitRunner.execute(in: path, ["merge-base", a, b],
                                        readOnly: true, timeout: Self.diffTimeout)
        guard out.status == 0 else { return nil }
        let oid = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    private func requireCommit(_ ref: String) throws -> String {
        guard let oid = try lookupCommit(ref) else {
            throw GitError(kind: .unknownRef(ref), description: "unknown revision '\(ref)'")
        }
        return oid
    }

    private func headRevision(_ comparison: GitComparison) throws -> String {
        switch comparison.head {
        case .workingTree: return try requireCommit("HEAD")
        case .ref(let ref): return try requireCommit(ref)
        }
    }

    private func rangeArgs(_ comparison: GitComparison, mergeBase: String, headRev: String) -> [String] {
        switch comparison.head {
        case .workingTree: return [mergeBase]
        case .ref: return [mergeBase, headRev]
        }
    }

    /// Index-cached and cheap; the text is part of the working-tree fingerprint.
    private func statusSnapshot() throws -> String {
        try read(["status", "--porcelain=v2", "-z", "--untracked-files=all"])
    }

    private func stamps(of paths: [String]) -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for p in paths { stamps[p] = stamp(of: p) }
        return stamps
    }

    /// The one place the working-tree token is built, shared by a load and a poll
    /// so that an unchanged tree yields equal strings.
    private func workingTreeFingerprint(base: String, headRev: String, status: String,
                                        paths: [String], stamps: [String: FileStamp]) -> String {
        let stampText = paths.sorted().map { p -> String in
            guard let s = stamps[p] else { return "\(p)=-" }
            return "\(p)=\(s.mtime):\(s.size)"
        }.joined(separator: "\n")
        return "wt:\(base):\(headRev)\n\(status)\n\(stampText)"
    }

    /// Raw stdout of a read-only call; non-zero exit throws.
    private func read(_ args: [String]) throws -> String {
        let out = try GitRunner.execute(in: path, args, readOnly: true,
                                        timeout: Self.diffTimeout, outputLimit: Self.diffOutputLimit)
        guard out.status == 0 else { throw failure(args, out) }
        return out.stdout
    }

    private func failure(_ args: [String], _ out: GitOutput) -> GitError {
        let message = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitError(kind: .failed(status: out.status),
                        description: message.isEmpty ? "git \(args.joined(separator: " ")) failed" : message)
    }

    private func stamp(of rel: String) -> FileStamp? {
        let full = (path as NSString).appendingPathComponent(rel)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: full) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileStamp(mtime: mtime, size: size)
    }

    /// Counts lines of an untracked file without git; over the cap, unreadable
    /// or not a regular file (a symlink's own size is its link text, and
    /// reading would follow it to the target) the counts stay nil and the
    /// file is never read.
    private func untrackedFile(_ rel: String) -> ChangedFile {
        let full = (path as NSString).appendingPathComponent(rel)
        let attrs = try? FileManager.default.attributesOfItem(atPath: full)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard (attrs?[.type] as? FileAttributeType) == .typeRegular,
              size <= Self.untrackedCountLimit,
              let data = FileManager.default.contents(atPath: full) else {
            return ChangedFile(path: rel, status: .added, added: nil, removed: nil, isUntracked: true)
        }
        if data.prefix(8000).contains(0) {
            return ChangedFile(path: rel, status: .added, added: nil, removed: nil,
                               isBinary: true, isUntracked: true)
        }
        var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if let last = data.last, last != 0x0A { lines += 1 }
        return ChangedFile(path: rel, status: .added, added: lines, removed: 0, isUntracked: true)
    }
}
