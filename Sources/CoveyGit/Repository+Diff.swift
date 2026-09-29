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
    public func resolveCommit(_ ref: String) -> String? {
        guard !ref.isEmpty, !ref.hasPrefix("-") else { return nil }
        return try? git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], readOnly: true)
    }

    public func mergeBase(_ a: String, _ b: String) -> String? {
        try? git(["merge-base", a, b], readOnly: true)
    }

    /// `main` → `master` → the branch `origin/HEAD` points at → nil. Not the
    /// current branch's upstream: an agent branch's upstream is its own
    /// remote copy, which would hide the branch's work.
    public func defaultBase() -> String? {
        for candidate in ["main", "master"] where branchExists(candidate) { return candidate }
        if let remote = try? git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                                 readOnly: true),
           !remote.isEmpty {
            return remote
        }
        return nil
    }

    public func changes(in comparison: GitComparison) throws -> ComparisonState {
        let base = try requireCommit(comparison.base)
        let headRev = try headRevision(comparison)
        guard let mergeBase = mergeBase(base, headRev) else {
            throw GitError(kind: .unknownRef(comparison.base),
                           description: "'\(comparison.base)' shares no history with \(headRev)")
        }
        let range = rangeArgs(comparison, mergeBase: mergeBase, headRev: headRev)
        let names = try read(["diff", "--no-color", "--no-ext-diff", "--name-status", "-z", "-M"] + range)
        let counts = Numstat.byPath(try read(["diff", "--no-color", "--no-ext-diff", "--numstat", "-z", "-M"] + range))

        var files = NameStatus.parse(names).map { entry -> ChangedFile in
            let c = counts[entry.path]
            return ChangedFile(path: entry.path, oldPath: entry.oldPath,
                               status: NameStatus.status(for: entry.code),
                               added: c?.added, removed: c?.removed,
                               isBinary: c.map { $0.added == nil && $0.removed == nil } ?? false)
        }
        var stamps: [String: FileStamp] = [:]
        if case .workingTree = comparison.head {
            let listed = Set(files.map(\.path))
            let untracked = try read(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"])
            for rel in untracked.split(separator: "\0").map(String.init) where !listed.contains(rel) {
                files.append(untrackedFile(rel))
            }
            for file in files { stamps[file.path] = stamp(of: file.path) }
        }
        files.sort { $0.path < $1.path }
        let fingerprint = try fingerprint(of: comparison, base: base, headRev: headRev,
                                          paths: files.map(\.path), stamps: stamps)
        return ComparisonState(mergeBase: mergeBase, files: files, stamps: stamps,
                               fingerprint: fingerprint)
    }

    /// Cheap "did anything change?" token. Working tree: base + HEAD commits,
    /// `status --porcelain=v2` (index-cached, so fast) and mtime/size of the
    /// already-changed `paths` — edits to files that were already dirty do not
    /// show in status. Ref…ref: the two resolved commits.
    public func fingerprint(of comparison: GitComparison, paths: [String]) throws -> String {
        let base = try requireCommit(comparison.base)
        let headRev = try headRevision(comparison)
        var stamps: [String: FileStamp] = [:]
        if case .workingTree = comparison.head {
            for p in paths { stamps[p] = stamp(of: p) }
        }
        return try fingerprint(of: comparison, base: base, headRev: headRev, paths: paths, stamps: stamps)
    }

    public func diff(of file: ChangedFile, in comparison: GitComparison, mergeBase: String,
                     fullFile: Bool = false) throws -> FileDiff {
        // `mergeBase` (normally `ComparisonState.mergeBase`, an object id) sits
        // before the `--` separator, so an option-shaped value must not reach git.
        guard !mergeBase.hasPrefix("-") else {
            throw GitError(kind: .unknownRef(mergeBase), description: "unknown revision '\(mergeBase)'")
        }
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if fullFile { args.append("--unified=1000000") }
        if file.isUntracked {
            args += ["--no-index", "--", "/dev/null", file.path]
            let out = try GitRunner.execute(in: path, args, readOnly: true,
                                            timeout: Self.diffTimeout, outputLimit: Self.diffOutputLimit)
            guard out.status == 0 || out.status == 1 else { throw failure(args, out) }
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

    private func requireCommit(_ ref: String) throws -> String {
        guard let oid = resolveCommit(ref) else {
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

    private func fingerprint(of comparison: GitComparison, base: String, headRev: String,
                             paths: [String], stamps: [String: FileStamp]) throws -> String {
        guard case .workingTree = comparison.head else { return "ref:\(base):\(headRev)" }
        let status = try read(["status", "--porcelain=v2", "-z", "--untracked-files=all"])
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
