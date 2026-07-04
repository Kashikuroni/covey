import Foundation
import CoveyKit

public enum RegistryError: Error, Equatable {
    case duplicateName(String)
    case notFound(String)
    case dirMissing(String)
}

/// In-memory registry of live sessions: name -> (Session, PTYProcess).
/// A process exit removes its entry automatically and notifies via `onExit`.
public final class SessionRegistry {
    /// Called when a session's process exits: (name, exit code).
    public var onExit: ((String, Int32) -> Void)?
    public var onSessionAdded: ((Session) -> Void)?
    public var onSessionRemoved: ((String) -> Void)?
    /// Fired when a pending restart respawned the session in place (the entry,
    /// name and screen survive; no exited/sessionRemoved accompany it).
    public var onRestarted: ((Session) -> Void)?
    private var entries: [String: (session: Session, process: PTYProcess,
                                   screen: ScreenModel, argv: [String],
                                   size: (cols: UInt16, rows: UInt16))] = [:]
    private var pendingRestart: [String: String] = [:]   // name -> respawn dir
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
        entries[id] = (session, proc, screen, argv, (80, 24))
        lock.unlock()
        persistNow()
        onSessionAdded?(session)
        return session
    }
    
    public func kill(name: String) {
        withEntry(name)?.process.kill()
    }

    /// Kills the session's child and respawns it in place once it exits:
    /// claude resumes its conversation, anything else reruns its argv. `dir`
    /// overrides the respawn directory (return-to-root). The entry, screen and
    /// name survive; no exited/sessionRemoved events fire.
    public func restart(name: String, dir: String? = nil) throws {
        lock.lock()
        guard let entry = entries[name] else {
            lock.unlock(); throw RegistryError.notFound(name)
        }
        let target = dir ?? entry.session.dir
        lock.unlock()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir),
              isDir.boolValue else {
            throw RegistryError.dirMissing(target)
        }
        lock.lock()
        pendingRestart[name] = target
        lock.unlock()
        kill(name: name)
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
        lock.lock()
        entries[name]?.size = (cols, rows)
        lock.unlock()
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
        guard let id = entries.first(where: { $0.value.process === proc })?.key,
              let entry = entries[id] else {
            lock.unlock()
            return
        }
        let restartDir = pendingRestart.removeValue(forKey: id)
        lock.unlock()

        // A dying claude prints its resume hint; re-read it so the stored
        // command survives /clear having rotated the conversation id.
        var freshResume: String?
        if entry.session.resumeCmd != nil {
            let tail = String(decoding: proc.scrollbackTail(4096), as: UTF8.self)
            freshResume = parseResumeCommand(tail)
        }

        if let restartDir,
           let respawned = respawn(id: id, dir: restartDir, resume: freshResume) {
            persistNow()
            onRestarted?(respawned)
            return
        }
        // No pending restart — or the respawn failed: normal exit path.

        lock.lock()
        var updated: Session?
        if let fresh = freshResume, fresh != entries[id]?.session.resumeCmd {
            entries[id]?.session.resumeCmd = fresh
            updated = entries[id]?.session
        }
        entries[id] = nil
        let removal = pendingWorktreeRemoval.removeValue(forKey: id)
        lock.unlock()
        persistNow()
        if let updated { onSessionAdded?(updated) }   // recents read the client cache
        if let removal {
            try? GitOps.removeWorktree(repo: removal.repo, wtPath: removal.path)
        }
        onExit?(id, code)
    }

    /// Respawns a pending-restart session in `dir`. Returns the updated
    /// session, or nil when the spawn failed (caller falls through to the
    /// normal exit path). Command resolution shells out — never under the lock.
    private func respawn(id: String, dir: String, resume: String?) -> Session? {
        lock.lock()
        guard let old = entries[id] else { lock.unlock(); return nil }
        lock.unlock()

        var session = old.session
        if let resume { session.resumeCmd = resume }
        let argv = session.resumeCmd.map { CreateService.resumeArgv($0) } ?? old.argv
        let proc = PTYProcess()
        proc.setExitHandler { [weak self, weak proc] code in
            guard let proc else { return }
            self?.handleExit(proc, code)
        }
        let screen = old.screen
        proc.setOutputHandler { bytes, _ in screen.feed(bytes) }
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: old.size.cols, rows: old.size.rows)
        } catch {
            return nil
        }
        session.dir = dir
        session.cwd = dir
        session.git = nil        // GitMonitor re-reads for the (possibly new) dir
        lock.lock()
        entries[id] = (session, proc, screen, argv, old.size)
        lock.unlock()
        return session
    }

}
