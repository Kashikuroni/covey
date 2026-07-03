import Foundation
import CoveyKit

public enum RegistryError: Error, Equatable {
    case duplicateName(String)
    case notFound(String)
}

/// In-memory registry of live sessions: name -> (Session, PTYProcess).
/// A process exit removes its entry automatically and notifies via `onExit`.
public final class SessionRegistry {
    /// Called when a session's process exits: (name, exit code).
    public var onExit: ((String, Int32) -> Void)?
    public var onSessionAdded: ((Session) -> Void)?
    public var onSessionRemoved: ((String) -> Void)?
    private var entries: [String: (session: Session, process: PTYProcess, screen: ScreenModel, argv: [String])] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0
    private var lostMetas: [SessionMeta]
    private let onPersist: (([SessionMeta]) -> Void)?
    private var pendingWorktreeRemoval: [String: (repo: String, path: String)] = [:]

    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) },
                persisted: [SessionMeta] = [],
                onPersist: (([SessionMeta]) -> Void)? = nil) {
        self.clock = clock
        self.lostMetas = persisted   // previous daemon life; surfaced, never respawned
        self.onPersist = onPersist
    }

    /// Sessions from the previous daemon life. The GUI merges them into its
    /// recents and acks with `clearLost()`.
    public var lost: [SessionMeta] {
        lock.lock(); defer { lock.unlock() }
        return lostMetas
    }

    public func clearLost() {
        lock.lock()
        lostMetas = []
        lock.unlock()
        persistNow()
    }

    /// Snapshots live + lost metas under the lock, then persists outside it.
    private func persistNow() {
        guard let onPersist else { return }
        lock.lock()
        let metas = entries.values.map {
            SessionMeta(name: $0.session.name, dir: $0.session.dir,
                        agent: $0.session.agent, argv: $0.argv,
                        created: $0.session.created,
                        worktreeRepo: $0.session.worktreeRepo,
                        resumeCmd: $0.session.resumeCmd)
        } + lostMetas
        lock.unlock()
        onPersist(metas)
    }
    
    public func create (
        dir: String,
        agent: String,
        argv: [String],
        name: String? = nil,
        worktreeRepo: String? = nil,
        resumeCmd: String? = nil
    ) throws -> Session {
        lock.lock()
        var autoNumber: Int?
        let id: String
        if let name {
            id = name
        } else {
            // Explicit names may occupy s-N; probe forward, commit only on success.
            var n = counter + 1
            while entries["s-\(n)"] != nil { n += 1 }
            autoNumber = n
            id = "s-\(n)"
        }
        if entries[id] != nil {
            lock.unlock()
            throw RegistryError.duplicateName(id)
        }
        let session = Session(
            name: id, dir: dir, cwd: dir, agent: agent,
            created: clock(), git: nil, worktreeRepo: worktreeRepo,
            resumeCmd: resumeCmd
        )
        let proc = PTYProcess()
        // Identify the entry by process, not by name: the exit may arrive
        // after a rename, when the create-time name no longer keys the entry.
        proc.setExitHandler { [weak self, weak proc] code in
            guard let proc else { return }
            self?.handleExit(proc, code)
        }
        let screen = ScreenModel(cols: 80, rows: 24)
        proc.setOutputHandler { bytes, _ in screen.feed(bytes) }
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: 80, rows: 24)
        } catch {
            lock.unlock()
            throw error
        }
        if let autoNumber { counter = autoNumber }
        entries[id] = (session, proc, screen, argv)
        lock.unlock()
        persistNow()
        onSessionAdded?(session)
        return session
    }
    
    public func kill(name: String) {
        withEntry(name)?.process.kill()
    }

    /// Updates a live session's cached git info (transient; not persisted).
    public func updateGit(name: String, git: GitInfo?) {
        lock.lock()
        entries[name]?.session.git = git
        lock.unlock()
    }

    /// Schedules the session's worktree for removal once its process exits.
    public func markWorktreeRemoval(name: String) {
        lock.lock()
        if let entry = entries[name], let repo = entry.session.worktreeRepo {
            pendingWorktreeRemoval[name] = (repo: repo, path: entry.session.dir)
        }
        lock.unlock()
    }

    public func list() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.session)
    }

    public func get(name: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]?.session
    }

    /// Snapshot of a session's process and screen under the lock; callers act
    /// on the pair outside it.
    private func withEntry(_ name: String) -> (process: PTYProcess, screen: ScreenModel)? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[name] else { return nil }
        return (entry.process, entry.screen)
    }
    
    public func attachOutput(
        name: String,
        _ handler: @escaping ([UInt8], Int) -> Void
    ) {
        lock.lock()
        guard let entry = entries[name] else { lock.unlock(); return }
        let proc = entry.process
        let screen = entry.screen
        lock.unlock()
        proc.setOutputHandler { bytes, seq in
            screen.feed(bytes)
            handler(bytes, seq)
        }
    }

    public func write(name: String, bytes: [UInt8]) {
        withEntry(name)?.process.write(bytes)
    }

    public func resize(name: String, cols: UInt16, rows: UInt16) {
        guard let entry = withEntry(name) else { return }
        entry.process.resize(cols: cols, rows: rows)
        entry.screen.resize(cols: Int(cols), rows: Int(rows))
    }
    
    public func rename(name: String, newName: String) throws {
        lock.lock()
        guard var entry = entries[name] else {
            lock.unlock(); throw RegistryError.notFound(name)
        }
        if entries[newName] != nil {
            lock.unlock(); throw RegistryError.duplicateName(newName)
        }
        entry.session.name = newName
        entries[name] = nil
        entries[newName] = entry
        lock.unlock()
        persistNow()
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
    }
    
    public func backfill(name: String, since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)? {
        withEntry(name)?.process.backfill(since: seq)
    }
    
    /// Visible screen text of every live session, for status inference.
    public func snapshotScreens() -> [String: String] {
        lock.lock()
        let screens = entries.mapValues(\.screen)
        lock.unlock()
        return screens.mapValues { $0.visibleText() }
    }

    private func handleExit(_ proc: PTYProcess, _ code: Int32) {
        lock.lock()
        let id = entries.first { $0.value.process === proc }?.key
        if let id { entries[id] = nil }
        let removal = id.flatMap { pendingWorktreeRemoval.removeValue(forKey: $0) }
        lock.unlock()
        persistNow()
        if let removal {
            try? GitOps.removeWorktree(repo: removal.repo, wtPath: removal.path)
        }
        if let id { onExit?(id, code) }
    }

}
