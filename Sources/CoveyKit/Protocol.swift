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
                    effort: String?, resume: String?, companionOf: String?,
                    env: [String: String]?, providerId: String?)
        case kill(name: String, removeWorktree: Bool?, deleteBranch: Bool?)
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
        case branchStatus(name: String)
        // SIGWINCH-kick the child into a full repaint (wheel-scroll of a TUI
        // leaves the alt buffer partially redrawn until the app repaints).
        case refresh(name: String)
        // Subscribe to a session's agent trace: reply is a `traceBacklog` with
        // events since `sinceSeq`, then live `traceAppended` events follow.
        case traceSubscribe(name: String, sinceSeq: Int?)
        case traceUnsubscribe(name: String)
    }
}

// Daemon -> client:
public enum ServerMessage: Codable, Equatable{
    case response(id: Int, result: Result)
    case event(DaemonEvent)
    
    public enum Result: Codable, Equatable {
        case ok
        case session(Session)
        // `lost` and `models` are optional so payloads from older daemons decode.
        case sessions(sessions: [Session], statuses: [String: Status], lost: [Session]?,
                      models: [String: String]?)
        // `worktrees` (branch -> path) is optional so older payloads decode.
        case gitInfo(repoRoot: String?, currentBranch: String?, branches: [String],
                     worktrees: [String: String]?)
        case branches([String])
        case branchStatus(dirty: Bool, merged: Bool)
        case error(code: String, message: String)
        // Reply to `traceSubscribe`: events since the requested cursor plus the
        // current total on-disk size of the trace store.
        case traceBacklog(events: [TraceEvent], storeBytes: Int)
    }
}

public enum DaemonEvent: Codable, Equatable {
    case output(name: String, seq: Int, bytesB64: String)
    case sessionAdded(session: Session)
    case sessionRemoved(name: String)
    case exited(name: String, code: Int32)
    case statusChanged(name: String, status: Status)
    case gitChanged(name: String, git: GitInfo?)
    case modelChanged(name: String, model: String)
    // Live agent-trace events for a session the client subscribed to, plus the
    // periodic total trace-store size for the header.
    case traceAppended(name: String, events: [TraceEvent])
    case traceStoreBytes(bytes: Int)
}
