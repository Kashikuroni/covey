import Foundation
import CoveyKit

/// Dispatches client requests against a `SessionRegistry` and multiplexes daemon
/// events onto registered client sinks. All mutable state (`sinks`, `subscribers`)
/// is confined to the serial `server` queue.
public final class IPCServer {
    private let registry: SessionRegistry
    private let monitor: StatusMonitor
    private let gitMonitor: GitMonitor?
    private let modelMonitor: ModelMonitor?
    private let server = DispatchQueue(label: "covey.ipc")
    private var sinks: [Int: ClientSink] = [:]
    private var subscribers: [String: Set<Int>] = [:]

    public init(registry: SessionRegistry, monitor: StatusMonitor,
                gitMonitor: GitMonitor? = nil, modelMonitor: ModelMonitor? = nil) {
        self.registry = registry
        self.monitor = monitor
        self.gitMonitor = gitMonitor
        self.modelMonitor = modelMonitor
        gitMonitor?.onGitChanged = { [weak self, weak registry] name, git in
            registry?.updateGit(name: name, git: git)
            self?.broadcast(.event(.gitChanged(name: name, git: git)))
        }
        modelMonitor?.onModelChanged = { [weak self] name, model in
            self?.broadcast(.event(.modelChanged(name: name, model: model)))
        }
        monitor.onStatusChanged = { [weak self] name, status in
            self?.broadcast(.event(.statusChanged(name: name, status: status)))
        }
        registry.onSessionAdded = { [weak self] s in
            self?.broadcast(.event(.sessionAdded(session: s)))
        }
        registry.onSessionRemoved = { [weak self] name in
            self?.broadcast(.event(.sessionRemoved(name: name)))
        }
        registry.onRestarted = { [weak self, weak gitMonitor, weak modelMonitor] s in
            guard let self else { return }
            // The respawn created a new PTYProcess — re-bind the output fanout
            // to it; subscribers are keyed by name and survive untouched.
            self.attachOutputFanout(for: s.name)
            // The respawn wiped the session's transient git info; make the
            // monitor re-emit even if the on-disk reading did not change,
            // and re-read right away (the dir may have changed too).
            gitMonitor?.forget(name: s.name)
            gitMonitor?.poke(name: s.name, dir: s.dir)
            modelMonitor?.poke(name: s.name, cwd: s.cwd, resumeCmd: s.resumeCmd)
            self.broadcast(.event(.sessionAdded(session: s)))   // client upserts
        }
        registry.onExit = { [weak self] name, code in
            guard let self else { return }
            self.broadcast(.event(.exited(name: name, code: code)))
            self.server.async { self.subscribers[name] = nil }
        }
    }

    public func register(_ sink: ClientSink) {
        server.async { [weak self] in self?.sinks[sink.id] = sink }
    }

    public func unregister(_ sink: ClientSink) {
        server.async { [weak self] in
            guard let self else { return }
            self.sinks[sink.id] = nil
            for name in self.subscribers.keys { self.subscribers[name]?.remove(sink.id) }
        }
    }

    public func handleBadRequest(id: Int?, from sink: ClientSink) {
        sink.send(.response(id: id ?? 0, result: .error(code: "badRequest", message: "malformed request")))
    }

    public func handle(_ request: Request, from sink: ClientSink) {
        server.async { [weak self] in self?.dispatch(request, sink) }
    }

    // MARK: - private (all on `server` queue)

    private func broadcast(_ message: ServerMessage) {
        server.async { [weak self] in
            guard let self else { return }
            for sink in self.sinks.values { sink.send(message) }
        }
    }

    private func dispatch(_ request: Request, _ sink: ClientSink) {
        let id = request.id
        func reply(_ r: ServerMessage.Result) { sink.send(.response(id: id, result: r)) }
        func notFound(_ name: String) { reply(.error(code: "notFound", message: "no session: \(name)")) }

        switch request.op {
        case .list:
            let sessions = registry.list()
            let known = monitor.currentStatuses()
            var statuses: [String: Status] = [:]
            for s in sessions { statuses[s.name] = known[s.name] ?? .idle }
            let lost = registry.lost.map {
                Session(name: $0.name, dir: $0.dir, cwd: $0.dir, agent: $0.agent,
                        created: $0.created, git: nil, worktreeRepo: $0.worktreeRepo,
                        resumeCmd: $0.resumeCmd)
            }
            reply(.sessions(sessions: sessions, statuses: statuses,
                            lost: lost.isEmpty ? nil : lost,
                            models: modelMonitor?.current()))

        case .clearLost:
            registry.clearLost(); reply(.ok)

        case let .create(dir, agent, argv, name, terminal, worktree, model, effort, resume, companionOf):
            do {
                // A companion's name is derived, never client-chosen.
                let effectiveName = companionOf.map { "\($0)+sh" } ?? name
                let s: Session
                if let argv {   // explicit argv: the raw path (tests, compatibility)
                    s = try registry.create(dir: dir, agent: agent, argv: argv,
                                            name: effectiveName, companionOf: companionOf)
                } else {
                    let spec = CreateSpec(name: effectiveName, dir: expandTilde(dir), agent: agent,
                                          terminal: terminal ?? false, worktree: worktree,
                                          model: model, effort: effort, resume: resume)
                    // Git IO runs here, outside any registry lock.
                    let prepared = try CreateService.prepare(spec)
                    s = try registry.create(dir: prepared.finalDir, agent: prepared.label,
                                            argv: prepared.argv, name: effectiveName,
                                            worktreeRepo: prepared.worktreeRepo,
                                            resumeCmd: prepared.resumeCmd,
                                            companionOf: companionOf)
                }
                attachOutputFanout(for: s.name)
                // The card's git line should not wait out the poll interval.
                gitMonitor?.poke(name: s.name, dir: s.dir)
                // A resumed session's transcript already exists — badge now.
                modelMonitor?.poke(name: s.name, cwd: s.cwd, resumeCmd: s.resumeCmd)
                reply(.session(s))
            } catch let e as RegistryError {
                reply(errorResult(e))
            } catch {
                reply(.error(code: "createFailed", message: "\(error)"))
            }

        case let .kill(name, removeWorktree, deleteBranch):
            guard registry.get(name: name) != nil else { return notFound(name) }
            if deleteBranch == true {
                registry.markBranchDeletion(name: name)
                registry.markWorktreeRemoval(name: name)   // delete needs the tree gone
            } else if removeWorktree == true {
                registry.markWorktreeRemoval(name: name)
            }
            registry.kill(name: name); reply(.ok)

        case let .restart(name, dir):
            guard registry.get(name: name) != nil else { return notFound(name) }
            do { try registry.restart(name: name, dir: dir); reply(.ok) }
            catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "restartFailed", message: "\(error)")) }

        case let .gitInfo(dir):
            let root = GitOps.repoRoot(expandTilde(dir))
            reply(.gitInfo(repoRoot: root,
                           currentBranch: root.flatMap { GitOps.currentBranch($0) },
                           branches: root.map { GitOps.localBranches($0) } ?? [],
                           worktrees: root.map { GitOps.worktrees($0) } ?? [:]))

        case let .promote(name):
            guard let session = registry.get(name: name) else { return notFound(name) }
            guard let repo = session.worktreeRepo else {
                return reply(.error(code: "promoteFailed", message: "not a worktree session"))
            }
            guard let branch = GitOps.currentBranch(session.dir) else {
                return reply(.error(code: "promoteFailed", message: "no branch checked out"))
            }
            // The companion shell lives inside the worktree — take it down
            // before the tree is removed.
            if let comp = registry.companionName(of: name) { registry.kill(name: comp) }
            do {
                try GitOps.promoteWorktree(repo: repo, wtDir: session.dir, branch: branch)
                reply(.ok)
            } catch { reply(.error(code: "promoteFailed", message: "\(error)")) }

        case let .deleteBranch(dir, branch):
            guard !protectedBranches.contains(branch) else {
                return reply(.error(code: "deleteBranchFailed",
                                    message: "branch '\(branch)' is protected"))
            }
            guard let repo = GitOps.repoRoot(expandTilde(dir)) else {
                return reply(.error(code: "deleteBranchFailed", message: "not a git repo"))
            }
            do { try GitOps.deleteBranch(repo: repo, branch: branch); reply(.ok) }
            catch { reply(.error(code: "deleteBranchFailed", message: "\(error)")) }

        case let .mergedBranches(dir):
            let repo = GitOps.repoRoot(expandTilde(dir))
            reply(.branches(repo.map { GitOps.listMergedBranches($0) } ?? []))

        case let .branchStatus(name):
            guard let session = registry.get(name: name) else { return notFound(name) }
            guard let repo = session.worktreeRepo,
                  let branch = GitOps.currentBranch(session.dir) else {
                return reply(.error(code: "branchStatusFailed",
                                    message: "not a worktree session"))
            }
            let dirty = GitOps.isDirty(session.dir)
            let merged = GitOps.listMergedBranches(repo).contains(branch)
            reply(.branchStatus(dirty: dirty, merged: merged))

        case let .cleanupBranches(dir, branches):
            guard let repo = GitOps.repoRoot(expandTilde(dir)) else {
                return reply(.error(code: "cleanupFailed", message: "not a git repo"))
            }
            var failures: [String] = []
            for branch in branches where !protectedBranches.contains(branch) {
                do { try GitOps.deleteBranch(repo: repo, branch: branch) }
                catch { failures.append("\(branch): \(error)") }
            }
            failures.isEmpty
                ? reply(.ok)
                : reply(.error(code: "cleanupFailed",
                               message: failures.joined(separator: "; ")))

        case let .rename(name, newName):
            do { try registry.rename(name: name, newName: newName); reply(.ok) }
            catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "badRequest", message: "\(error)")) }

        case let .attach(name, sinceSeq):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name, default: []].insert(sink.id)
            // A fresh GUI emulator needs the session's private-mode state
            // (alt screen, mouse tracking) before the raw tail: those DECSETs
            // were emitted once at process start and are usually evicted from
            // the ring, leaving a re-attached terminal in the normal buffer.
            let preamble = registry.statePreamble(name: name) ?? []
            let bf = registry.backfill(name: name, since: sinceSeq ?? 0)
            let payload = preamble + (bf?.bytes ?? [])
            if !payload.isEmpty {
                sink.send(.event(.output(name: name, seq: bf?.fromSeq ?? 0,
                                         bytesB64: Data(payload).base64EncodedString())))
            }
            registry.kick(name: name)
            reply(.ok)

        case let .detach(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name]?.remove(sink.id); reply(.ok)

        case let .refresh(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            registry.kick(name: name); reply(.ok)

        case let .input(name, bytesB64):
            guard registry.get(name: name) != nil else { return notFound(name) }
            guard let data = Data(base64Encoded: bytesB64) else {
                return reply(.error(code: "badRequest", message: "invalid base64"))
            }
            registry.write(name: name, bytes: [UInt8](data)); reply(.ok)

        case let .resize(name, cols, rows):
            guard registry.get(name: name) != nil else { return notFound(name) }
            registry.resize(name: name, cols: cols, rows: rows); reply(.ok)
        }
    }

    private func attachOutputFanout(for name: String) {
        registry.attachOutput(name: name) { [weak self] bytes, seq in
            guard let self else { return }
            self.server.async {
                guard let subs = self.subscribers[name], !subs.isEmpty else { return }
                let msg = ServerMessage.event(.output(name: name, seq: seq,
                                                      bytesB64: Data(bytes).base64EncodedString()))
                for id in subs { self.sinks[id]?.send(msg) }
            }
        }
    }

    private func errorResult(_ e: RegistryError) -> ServerMessage.Result {
        switch e {
        case .notFound(let n):      return .error(code: "notFound", message: "no session: \(n)")
        case .duplicateName(let n): return .error(code: "duplicateName", message: "name taken: \(n)")
        case .dirMissing(let d):
            return .error(code: "restartFailed", message: "directory missing: \(d)")
        }
    }
}
