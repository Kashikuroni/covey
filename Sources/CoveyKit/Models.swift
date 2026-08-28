public struct GitDiffSummary: Codable, Equatable {
    public var files: UInt32
    public var added: UInt32
    public var removed: UInt32

    public init(files: UInt32, added: UInt32, removed: UInt32) {
        self.files = files
        self.added = added
        self.removed = removed
    }

    public static let empty = GitDiffSummary(files: 0, added: 0, removed: 0)
}

public struct GitInfo: Codable, Equatable {
    public var branch: String
    public var unstaged: GitDiffSummary
    public var staged: GitDiffSummary
    public var untracked: UInt32
    public var added: UInt32 {
        get { unstaged.added }
        set {
            unstaged.added = newValue
            normalizeLegacyFileCount()
        }
    }
    public var removed: UInt32 {
        get { unstaged.removed }
        set {
            unstaged.removed = newValue
            normalizeLegacyFileCount()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case branch, added, removed, unstaged, staged, untracked
    }

    public init(branch: String, unstaged: GitDiffSummary,
                staged: GitDiffSummary, untracked: UInt32) {
        self.branch = branch
        self.unstaged = unstaged
        self.staged = staged
        self.untracked = untracked
    }

    public init(branch: String, added: UInt32, removed: UInt32) {
        self.init(
            branch: branch,
            unstaged: GitDiffSummary(
                files: added == 0 && removed == 0 ? 0 : 1,
                added: added,
                removed: removed
            ),
            staged: .empty,
            untracked: 0
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        branch = try container.decode(String.self, forKey: .branch)
        let legacyAdded = try container.decodeIfPresent(UInt32.self, forKey: .added) ?? 0
        let legacyRemoved = try container.decodeIfPresent(UInt32.self, forKey: .removed) ?? 0
        unstaged = try container.decodeIfPresent(GitDiffSummary.self, forKey: .unstaged)
            ?? GitDiffSummary(
                files: legacyAdded == 0 && legacyRemoved == 0 ? 0 : 1,
                added: legacyAdded,
                removed: legacyRemoved
            )
        staged = try container.decodeIfPresent(GitDiffSummary.self, forKey: .staged) ?? .empty
        untracked = try container.decodeIfPresent(UInt32.self, forKey: .untracked) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branch, forKey: .branch)
        try container.encode(unstaged.added, forKey: .added)
        try container.encode(unstaged.removed, forKey: .removed)
        try container.encode(unstaged, forKey: .unstaged)
        try container.encode(staged, forKey: .staged)
        try container.encode(untracked, forKey: .untracked)
    }

    private mutating func normalizeLegacyFileCount() {
        if unstaged.added > 0 || unstaged.removed > 0 {
            unstaged.files = max(1, unstaged.files)
        }
    }
}

public struct Session: Codable, Equatable {
    public var name: String
    public var dir: String
    public var cwd: String
    public var agent: String
    public var created: Int64
    public var git: GitInfo?
    public var worktreeRepo: String?
    /// "claude --resume <uuid>" for cold-start relaunch; nil for non-claude.
    public var resumeCmd: String?
    /// Name of the parent session when this is a split companion shell;
    /// nil for regular sessions. Companions are hidden from the GUI lists.
    public var companionOf: String?
    /// Claude-compatible provider used to create this session; nil means
    /// Anthropic or a payload written before provider identity was persisted.
    public var providerId: String?

    public init(
        name: String, dir: String, cwd: String, agent: String,
        created: Int64, git: GitInfo? = nil, worktreeRepo: String? = nil,
        resumeCmd: String? = nil, companionOf: String? = nil,
        providerId: String? = nil
    ) {
        self.name = name
        self.dir = dir
        self.cwd = cwd
        self.agent = agent
        self.created = created
        self.git = git
        self.worktreeRepo = worktreeRepo
        self.resumeCmd = resumeCmd
        self.companionOf = companionOf
        self.providerId = providerId
    }
}

public enum Status: String, Codable, Equatable {
    case running, waiting, idle
}

/// Branches that destructive git actions refuse to touch (git.rs port).
public let protectedBranches = ["main", "master", "develop", "dev"]
