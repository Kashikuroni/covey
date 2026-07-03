import Darwin
import Foundation

public enum IPCClientError: Error, Equatable {
    case notConnected                                  // request before connect() / after close()
    case connectFailed(Int32)                          // errno from connect(2), or ETIMEDOUT
    case daemonError(code: String, message: String)    // .error result from the daemon
    case disconnected                                  // EOF/teardown while a request was pending
}

/// Client side of the coveyd NDJSON unix-socket protocol. One instance = one
/// connection; after a disconnect the instance is dead — the GUI runs
/// `DaemonLauncher.ensureDaemon` and builds a fresh client (HANDOFF "GUI
/// restart" semantics). All mutable state is confined to the serial `queue`.
public final class IPCClient {
    /// Every daemon event, including `output`. Single long-lived stream,
    /// unbounded buffer, finishes on EOF or `close()`.
    public let events: AsyncStream<DaemonEvent>

    private let path: String
    private let queue = DispatchQueue(label: "covey.ipc-client")
    private let eventsContinuation: AsyncStream<DaemonEvent>.Continuation
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var pending: [Int: CheckedContinuation<ServerMessage.Result, Error>] = [:]
    private var nextID = 0
    private var connected = false
    private var closed = false

    public init(path: String) {
        self.path = path
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: DaemonEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        readSource?.cancel()          // closes the fd via the cancel handler
        eventsContinuation.finish()
    }

    public func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw IPCClientError.connectFailed(errno) }
        // A write after the daemon closed must return EPIPE, not raise SIGPIPE.
        var on: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard UnixSocket.connect(sock, to: path) == 0 else {
            let e = errno
            Darwin.close(sock)
            throw IPCClientError.connectFailed(e)
        }
        queue.sync {
            fd = sock
            connected = true
            let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
            src.setEventHandler { [weak self] in self?.handleReadable() }
            src.setCancelHandler { Darwin.close(sock) }
            readSource = src
            src.resume()
        }
    }

    public func close() {
        queue.async { [weak self] in self?.teardown() }
    }

    // MARK: - typed requests

    public func list() async throws -> (sessions: [Session], statuses: [String: Status], lost: [Session]?) {
        if case let .sessions(sessions, statuses, lost) = try await request(.list) {
            return (sessions, statuses, lost)
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected sessions")
    }

    public func create(dir: String, agent: String, argv: [String]? = nil,
                       name: String? = nil, terminal: Bool? = nil,
                       worktree: WorktreeSpec? = nil, model: String? = nil,
                       effort: String? = nil, resume: String? = nil) async throws -> Session {
        if case let .session(s) = try await request(
            .create(dir: dir, agent: agent, argv: argv, name: name,
                    terminal: terminal, worktree: worktree, model: model,
                    effort: effort, resume: resume)) {
            return s
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected session")
    }

    public func gitInfo(dir: String) async throws
        -> (repoRoot: String?, currentBranch: String?, branches: [String]) {
        if case let .gitInfo(root, current, branches) = try await request(.gitInfo(dir: dir)) {
            return (root, current, branches)
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected gitInfo")
    }

    public func kill(name: String, removeWorktree: Bool? = nil) async throws {
        try await expectOK(.kill(name: name, removeWorktree: removeWorktree))
    }

    public func clearLost() async throws {
        try await expectOK(.clearLost)
    }

    public func promote(name: String) async throws {
        try await expectOK(.promote(name: name))
    }

    public func deleteBranch(dir: String, branch: String) async throws {
        try await expectOK(.deleteBranch(dir: dir, branch: branch))
    }

    public func mergedBranches(dir: String) async throws -> [String] {
        if case let .branches(list) = try await request(.mergedBranches(dir: dir)) {
            return list
        }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected branches")
    }

    public func cleanupBranches(dir: String, branches: [String]) async throws {
        try await expectOK(.cleanupBranches(dir: dir, branches: branches))
    }

    public func rename(name: String, newName: String) async throws {
        try await expectOK(.rename(name: name, newName: newName))
    }

    public func attach(name: String, sinceSeq: Int? = nil) async throws {
        try await expectOK(.attach(name: name, sinceSeq: sinceSeq))
    }

    public func detach(name: String) async throws {
        try await expectOK(.detach(name: name))
    }

    public func input(name: String, bytes: [UInt8]) async throws {
        try await expectOK(.input(name: name, bytesB64: Data(bytes).base64EncodedString()))
    }

    public func resize(name: String, cols: UInt16, rows: UInt16) async throws {
        try await expectOK(.resize(name: name, cols: cols, rows: rows))
    }

    // MARK: - private

    private func expectOK(_ op: Request.Op) async throws {
        if case .ok = try await request(op) { return }
        throw IPCClientError.daemonError(code: "badResponse", message: "expected ok")
    }

    private func request(_ op: Request.Op) async throws -> ServerMessage.Result {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    return cont.resume(throwing: IPCClientError.disconnected)
                }
                guard self.connected, !self.closed else {
                    return cont.resume(throwing: IPCClientError.notConnected)
                }
                self.nextID += 1
                let id = self.nextID
                guard let line = try? NDJSON.encodeLine(Request(id: id, op: op)) else {
                    return cont.resume(throwing: IPCClientError.daemonError(
                        code: "badResponse", message: "request encoding failed"))
                }
                self.pending[id] = cont
                self.writeLine(line)
            }
        }
    }

    /// On `queue`. A failed write is not reported here: the read side will
    /// observe EOF and tear down, failing all pending requests.
    private func writeLine(_ line: [UInt8]) {
        line.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n > 0 {
                    base = base.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// On `queue`.
    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            guard let lines = try? framer.feed(Array(buf[0..<n])) else { return teardown() }
            for line in lines { dispatchLine(line) }
        } else {
            teardown()
        }
    }

    /// On `queue`. Unparseable lines are ignored (trust the daemon, don't die).
    private func dispatchLine(_ line: [UInt8]) {
        guard let msg = try? NDJSON.decoder.decode(ServerMessage.self, from: Data(line)) else {
            return
        }
        switch msg {
        case let .response(id, result):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if case let .error(code, message) = result {
                cont.resume(throwing: IPCClientError.daemonError(code: code, message: message))
            } else {
                cont.resume(returning: result)
            }
        case let .event(e):
            eventsContinuation.yield(e)
        }
    }

    /// On `queue`. Idempotent: EOF, close(), and framer errors all land here.
    private func teardown() {
        guard !closed else { return }
        closed = true
        connected = false
        readSource?.cancel()      // cancel handler closes the fd
        readSource = nil
        fd = -1
        for (_, cont) in pending {
            cont.resume(throwing: IPCClientError.disconnected)
        }
        pending.removeAll()
        eventsContinuation.finish()
    }
}
