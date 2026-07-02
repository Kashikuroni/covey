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
    private var entries: [String: (session: Session, process: PTYProcess, screen: ScreenModel)] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0
    
    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) }) {
        self.clock = clock
    }
    
    public func create (
        dir: String,
        agent: String,
        argv: [String],
        name: String? = nil
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
            created: clock(), git: nil, worktreeRepo: nil
        )
        let proc = PTYProcess()
        proc.setExitHandler { [weak self] code in self?.handleExit(id, code)}
        let screen = ScreenModel(cols: 80, rows: 24)
        proc.setOutputHandler { bytes, _ in screen.feed(bytes) }
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: 80, rows: 24)
        } catch {
            lock.unlock()
            throw error
        }
        if let autoNumber { counter = autoNumber }
        entries[id] = (session, proc, screen)
        lock.unlock()
        onSessionAdded?(session)
        return session
    }
    
    public func kill(name: String) {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.kill()
    }

    public func list() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.session)
    }

    public func get(name: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]?.session
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
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        proc?.write(bytes)
    }

    public func resize(name: String, cols: UInt16, rows: UInt16) {
        lock.lock()
        let proc = entries[name]?.process
        let screen = entries[name]?.screen
        lock.unlock()
        proc?.resize(cols: cols, rows: rows)
        screen?.resize(cols: Int(cols), rows: Int(rows))
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
        onSessionRemoved?(name)
        onSessionAdded?(entry.session)
    }
    
    public func backfill(name: String, since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)? {
        lock.lock()
        let proc = entries[name]?.process
        lock.unlock()
        return proc?.backfill(since: seq)
    }
    
    /// Visible screen text of every live session, for status inference.
    public func snapshotScreens() -> [String: String] {
        lock.lock()
        let screens = entries.mapValues(\.screen)
        lock.unlock()
        return screens.mapValues { $0.visibleText() }
    }

    private func handleExit(_ id: String, _ code: Int32) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
        onExit?(id, code)
    }

}
