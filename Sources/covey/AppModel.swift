import Foundation
import Observation
import CoveyKit

/// UI state machine. The daemon is the single source of truth about sessions:
/// actions call the IPC client and the model mutates only when the daemon's
/// events confirm the change. One instance owns the single `client.events`
/// consumer (the stream delivers each element to exactly one iterator).
@Observable @MainActor
public final class AppModel {
    public enum Modal: Equatable {
        case newSession
        case kill(String)
        case rename(String)
    }

    public private(set) var sessions: [Session] = []       // sorted by created
    public private(set) var statusByName: [String: Status] = [:]
    public private(set) var selected: String?
    public var modal: Modal?
    public private(set) var toast: String?
    public private(set) var connected = false

    /// Bytes for the currently attached session's terminal view. The terminal
    /// view mounts asynchronously after `selected` changes, so output (notably
    /// the attach backfill) can arrive before the sink exists — those bytes are
    /// buffered and flushed here the moment the view sets its sink.
    public var onTerminalOutput: (([UInt8]) -> Void)? {
        didSet {
            guard let sink = onTerminalOutput, !outputBuffer.isEmpty else { return }
            let pending = outputBuffer
            outputBuffer = []
            sink(pending)
        }
    }
    private var outputBuffer: [UInt8] = []

    private var client: IPCClient
    private let makeClient: () throws -> IPCClient
    private var eventLoop: Task<Void, Never>?

    public init(client: IPCClient, makeClient: @escaping () throws -> IPCClient) {
        self.client = client
        self.makeClient = makeClient
    }

    public func start() async {
        do {
            let (list, statuses) = try await client.list()
            sessions = list.sorted { $0.created < $1.created }
            statusByName = statuses
            connected = true
            toast = nil
        } catch {
            connected = false
            toast = errorText(error)
            return
        }
        eventLoop?.cancel()
        // Inherits MainActor: apply() and the trailing mutations run on the actor.
        eventLoop = Task { [client] in
            for await event in client.events {
                self.apply(event)
            }
            self.connected = false
            self.toast = "daemon connection lost"
        }
    }

    public func select(_ name: String?) async {
        guard name != selected else { return }
        if let old = selected {
            try? await client.detach(name: old)
        }
        outputBuffer = []          // drop any bytes buffered for the old session
        selected = name
        if let name {
            do { try await client.attach(name: name, sinceSeq: 0) }
            catch { toast = errorText(error) }
        }
    }

    public func create(dir: String, agent: String) async {
        do { _ = try await client.create(dir: dir, agent: agent) }
        catch { toast = errorText(error) }
    }

    public func kill(_ name: String) async {
        do { try await client.kill(name: name) }
        catch { toast = errorText(error) }
    }

    public func rename(_ name: String, to newName: String) async {
        do { try await client.rename(name: name, newName: newName) }
        catch { toast = errorText(error) }
    }

    public func sendInput(_ bytes: [UInt8]) async {
        guard let selected else { return }
        try? await client.input(name: selected, bytes: bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) async {
        guard let selected else { return }
        try? await client.resize(name: selected, cols: cols, rows: rows)
    }

    public func reconnect() async {
        do {
            client = try makeClient()
            toast = nil
        } catch {
            toast = errorText(error)
            return
        }
        let previous = selected
        selected = nil                     // start() re-lists; drop stale selection
        await start()
        // Re-attach only if the session survived (a fresh daemon lost it — no
        // persistence yet — so don't attach a ghost and toast "not found").
        if let previous, sessions.contains(where: { $0.name == previous }) {
            await select(previous)
        }
    }

    // MARK: - private

    private func apply(_ event: DaemonEvent) {
        switch event {
        case let .sessionAdded(session):
            sessions.removeAll { $0.name == session.name }
            sessions.append(session)
            sessions.sort { $0.created < $1.created }
        case .sessionRemoved(let name), .exited(let name, _):
            sessions.removeAll { $0.name == name }
            statusByName[name] = nil
            if selected == name { selected = nil }
        case let .statusChanged(name, status):
            statusByName[name] = status
        case let .output(name, _, bytesB64):
            guard name == selected, let data = Data(base64Encoded: bytesB64) else { return }
            let bytes = [UInt8](data)
            if let sink = onTerminalOutput {
                sink(bytes)
            } else {
                outputBuffer.append(contentsOf: bytes)   // flushed when the view mounts
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if case let IPCClientError.daemonError(code, message) = error {
            return "\(code): \(message)"
        }
        return "\(error)"
    }
}
