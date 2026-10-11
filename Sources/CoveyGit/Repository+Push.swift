import Foundation

/// Where the current branch publishes, and how it diverged at last fetch.
public struct UpstreamInfo: Equatable, Sendable {
    public var remote: String
    public var branch: String     // remote-side branch name, e.g. "dev"
    public var ahead: Int
    public var behind: Int

    public init(remote: String, branch: String, ahead: Int, behind: Int) {
        self.remote = remote
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
    }
}

extension Repository {
    /// Credential prompts must fail fast, never hang: terminal prompts off and
    /// an askpass that returns nothing (donor: feat/git-window's GitOps).
    static let networkEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/true",
    ]

    /// The current branch's upstream plus ahead/behind at last fetch.
    /// nil when detached, without upstream, or the upstream is gone.
    public func upstreamInfo() throws -> UpstreamInfo? {
        guard let branch = currentBranch() else { return nil }
        let line = try git(["for-each-ref", "--format=%(upstream:short)",
                            "refs/heads/\(branch)"], readOnly: true)
        let upstream = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstream.isEmpty else { return nil }
        guard let slash = upstream.firstIndex(of: "/") else { return nil }
        let remote = String(upstream[..<slash])
        let remoteBranch = String(upstream[upstream.index(after: slash)...])

        // Left = only in upstream (behind), right = only here (ahead).
        let counts = (try? git(["rev-list", "--left-right", "--count",
                                "\(upstream)...HEAD"], readOnly: true)) ?? ""
        let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return nil                                             // gone upstream
        }
        return UpstreamInfo(remote: remote, branch: remoteBranch, ahead: ahead, behind: behind)
    }

    /// Pushes the current branch; `-u` publishes it under `remote`.
    public func push(remote: String = "origin", setUpstream: Bool = false) throws {
        guard let branch = currentBranch() else {
            throw GitError("detached HEAD — switch to a branch before pushing")
        }
        var args = ["push"]
        if setUpstream { args += ["-u", remote, branch] }
        else { args += [remote, branch] }
        try git(args, additionalEnvironment: Self.networkEnvironment)
    }

    public func fetch(remote: String) throws {
        try git(["fetch", "--quiet", remote],
                additionalEnvironment: Self.networkEnvironment)
    }
}
