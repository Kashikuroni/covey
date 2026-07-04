// Client -> daemon
public struct Request: Codable, Equatable {
    public var id: Int
    public var op: Op
    
    public init(id: Int, op: Op) {
        self.id = id; self.op = op
    }
    public enum Op: Codable, Equatable{
        case list
        case clearLost
        case create(dir: String, agent: String, argv: [String]?, name: String?,
                    terminal: Bool?, worktree: WorktreeSpec?, model: String?,
                    effort: String?, resume: String?, companionOf: String?)
        case kill(name: String, removeWorktree: Bool?)
        // Kill the child and respawn it in place; `dir` overrides the respawn
        // directory (return-to-root). claude resumes, other agents rerun argv.
        case restart(name: String, dir: String?)
        case rename(name: String, newName: String)
        case attach(name: String, sinceSeq: Int?)
        case detach(name: String)
        case input(name: String, bytesB64: String)
        case resize(name: String, cols: UInt16, rows: UInt16)
        case gitInfo(dir: String)
        case promote(name: String)
        case deleteBranch(dir: String, branch: String)
        case mergedBranches(dir: String)
        case cleanupBranches(dir: String, branches: [String])
    }
}

// Daemon -> client:
public enum ServerMessage: Codable, Equatable{
    case response(id: Int, result: Result)
    case event(DaemonEvent)
    
    public enum Result: Codable, Equatable {
        case ok
        case session(Session)
        // `lost` is optional so payloads from older daemons decode as nil.
        case sessions(sessions: [Session], statuses: [String: Status], lost: [Session]?)
        // `worktrees` (branch -> path) is optional so older payloads decode.
        case gitInfo(repoRoot: String?, currentBranch: String?, branches: [String],
                     worktrees: [String: String]?)
        case branches([String])
        case error(code: String, message: String)
    }
}

public enum DaemonEvent: Codable, Equatable {
    case output(name: String, seq: Int, bytesB64: String)
    case sessionAdded(session: Session)
    case sessionRemoved(name: String)
    case exited(name: String, code: Int32)
    case statusChanged(name: String, status: Status)
    case promptChanged(name: String, options: [String])
    case gitChanged(name: String, git: GitInfo?)
}
