public struct GitInfo: Codable, Equatable {
    public var branch: String
    public var added: UInt32
    public var removed: UInt32
    
    public init(branch: String, added: UInt32, removed: UInt32) {
        self.branch = branch
        self.added = added
        self.removed = removed
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
