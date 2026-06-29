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
    private var entries: [String: (session: Session, process: PTYProcess)] = [:]
    private let lock = NSLock()
    private let clock: () -> Int64
    private var counter = 0
    
    public init(clock: @escaping () -> Int64 = { Int64(time(nil)) }) {
        self.clock = clock
    }
    
    public func create (
        dir: String, agent: String, argv: [String], name: String? = nil
    ) throws -> Session {
        lock.lock()
        counter += 1
        let id = name ?? "s-\(counter)"
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
        do {
            try proc.spawn(argv: argv, cwd: dir, cols: 80, rows: 24)
        } catch {
            lock.unlock()
            throw error
        }
        entries[id] = (session, proc)
        lock.unlock()
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
        let proc = entries[name]?.process
        lock.unlock()
        proc?.setOutputHandler(handler)
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
        lock.unlock()
        proc?.resize(cols: cols, rows: rows)
    }
    
    private func handleExit(_ id: String, _ code: Int32) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
        onExit?(id, code)
    }

}
