import Foundation

extension Repository {
    /// Committer epoch seconds of the checkout's HEAD; nil when unreadable.
    public func lastCommitTimestamp() throws -> Int64? {
        let out = try git(["log", "-1", "--format=%ct"], readOnly: true)
        return Int64(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How `branch` diverged from `base`: commits only in the branch (ahead)
    /// and only in base (behind).
    public func aheadBehind(branch: String, base: String) throws -> (ahead: Int, behind: Int) {
        let out = try git(["rev-list", "--left-right", "--count",
                           "\(base)...\(branch)"], readOnly: true)
        let parts = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            throw GitError("could not count commits between '\(base)' and '\(branch)'")
        }
        return (ahead, behind)
    }
}
