import Foundation

extension Repository {
    /// True when at least one path has a staged change (porcelain x ≠ '.').
    public func hasStagedChanges() throws -> Bool {
        try indexStatus().contains { $0.staged }
    }

    /// Commits the staged set via a message file (arbitrary text is safe —
    /// no shell, no `-m` quoting). Hooks run; `--cleanup=whitespace` keeps
    /// `#` lines in the body. Returns the new HEAD OID.
    public func commit(summary: String, body: String = "", amend: Bool = false) throws -> String {
        guard currentBranch() != nil else {
            throw GitError("detached HEAD — switch to a branch before committing")
        }
        if !amend, !(try hasStagedChanges()) {
            throw GitError("nothing is staged — stage changes before committing")
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError("commit summary is empty")
        }
        let messageFile = "\(NSTemporaryDirectory())covey-commit-\(UInt32.random(in: 0..<UInt32.max)).txt"
        let message = body.isEmpty ? summary : "\(summary)\n\n\(body)"
        try message.write(toFile: messageFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: messageFile) }

        var args = ["commit", "-F", messageFile, "--cleanup=whitespace"]
        if amend {
            // A message-only amend (nothing staged) is legitimate — git would
            // otherwise refuse it as "would make it empty".
            args += ["--amend", "--allow-empty"]
        }
        try git(args)
        return try git(["rev-parse", "HEAD"], readOnly: true)
    }
}
