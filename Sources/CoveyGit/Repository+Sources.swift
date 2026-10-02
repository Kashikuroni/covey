import Foundation

/// Whole-tree reads for the Review graph (links between files). `path` must
/// be the worktree toplevel — a review's worktree always is — because git
/// takes and prints these paths relative to it. Read-only: none of them
/// takes the index lock.
extension Repository {
    /// Words per `git grep` call.
    public static let grepBatch = 200

    /// Every file of `revision`, repo-relative and sorted
    /// (`git ls-tree -r --name-only -z`).
    public func files(at revision: String) throws -> [String] {
        Self.nulList(try sourceRead(["ls-tree", "-r", "--name-only", "-z", try Self.revisionArg(revision)]))
    }

    /// The working tree's tracked and untracked files, ignored ones left
    /// out, sorted (`git ls-files -co --exclude-standard -z`). A tracked file
    /// deleted from disk but still in the index is listed.
    public func workingTreeFiles() throws -> [String] {
        Self.nulList(try sourceRead(["ls-files", "-co", "--exclude-standard", "-z"]))
    }

    /// The bytes of `path` at `revision`; nil when there is no such file, it
    /// is not a file (a directory, a submodule) or it is larger than
    /// `maxBytes`. The size is asked first, so a big blob is never read.
    public func blob(_ path: String, at revision: String, maxBytes: Int) throws -> Data? {
        let object = "\(try Self.revisionArg(revision)):\(path)"
        let size = try GitRunner.executeRaw(in: self.path, ["cat-file", "-s", object], readOnly: true,
                                            timeout: Self.diffTimeout)
        guard size.status == 0,
              let bytes = Int(String(decoding: size.stdout, as: UTF8.self)
                                  .trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes <= maxBytes else { return nil }
        let blob = try GitRunner.executeRaw(in: self.path, ["cat-file", "blob", object], readOnly: true,
                                            timeout: Self.diffTimeout, outputLimit: maxBytes + (64 << 10))
        return blob.status == 0 ? blob.stdout : nil
    }

    /// Files that contain at least one of `words` as a whole word: at
    /// `revision`, or — when it is nil — in the working tree (tracked and
    /// untracked, not ignored). Binary files are skipped. One
    /// `git grep -l -w -F` per `grepBatch` words; exit 1 is "no match".
    public func filesMentioning(_ words: [String], at revision: String?) throws -> [String] {
        let unique = Set(words.filter { !$0.isEmpty }).sorted()
        let rev = try revision.map(Self.revisionArg)
        var found = Set<String>()
        for start in stride(from: 0, to: unique.count, by: Self.grepBatch) {
            var args = ["grep", "-l", "-w", "-F", "-z", "-I", "--no-color"]
            if rev == nil { args.append("--untracked") }
            for word in unique[start..<min(start + Self.grepBatch, unique.count)] { args += ["-e", word] }
            if let rev { args.append(rev) }
            args.append("--")
            let out = try GitRunner.executeRaw(in: path, args, readOnly: true, timeout: Self.diffTimeout,
                                               outputLimit: Self.diffOutputLimit)
            if out.status == 1 { continue }
            guard out.status == 0 else { throw Self.sourceFailure(args, out) }
            // At a revision git names each file `<revision>:<path>`.
            let prefix = rev.map { "\($0):" } ?? ""
            for name in Self.nulList(out.stdout) {
                found.insert(name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name)
            }
        }
        return found.sorted()
    }

    // MARK: - private

    private func sourceRead(_ args: [String]) throws -> Data {
        let out = try GitRunner.executeRaw(in: path, args, readOnly: true, timeout: Self.diffTimeout,
                                           outputLimit: Self.diffOutputLimit)
        guard out.status == 0 else { throw Self.sourceFailure(args, out) }
        return out.stdout
    }

    /// A revision goes before `--`, so an empty or option-shaped one never
    /// reaches git.
    private static func revisionArg(_ revision: String) throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("-") else {
            throw GitError(kind: .unknownRef(revision), description: "unknown revision '\(revision)'")
        }
        return revision
    }

    /// NUL-separated names, sorted, without duplicates (an unmerged path is
    /// listed once per stage).
    private static func nulList(_ data: Data) -> [String] {
        Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }).sorted()
    }

    private static func sourceFailure(_ args: [String], _ out: ProcessResult) -> GitError {
        let message = String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitError(kind: .failed(status: out.status),
                        description: message.isEmpty ? "git \(args.joined(separator: " ")) failed" : message)
    }
}
