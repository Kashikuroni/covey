import Foundation
import CoveyKit

/// Dispatches client requests against a `SessionRegistry` and multiplexes daemon
/// events onto registered client sinks. All mutable state (`sinks`, `subscribers`)
/// is confined to the serial `server` queue.
public final class IPCServer {
    private let registry: SessionRegistry
    private let monitor: StatusMonitor
    private let server = DispatchQueue(label: "covey.ipc")
    private var sinks: [Int: ClientSink] = [:]
    private var subscribers: [String: Set<Int>] = [:]

    public init(registry: SessionRegistry, monitor: StatusMonitor) {
        self.registry = registry
        self.monitor = monitor
        monitor.onStatusChanged = { [weak self] name, status in
            self?.broadcast(.event(.statusChanged(name: name, status: status)))
        }
        registry.onSessionAdded = { [weak self] s in
            self?.broadcast(.event(.sessionAdded(session: s)))
        }
        registry.onSessionRemoved = { [weak self] name in
            self?.broadcast(.event(.sessionRemoved(name: name)))
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
                        created: $0.created, git: nil, worktreeRepo: nil)
            }
            reply(.sessions(sessions: sessions, statuses: statuses,
                            lost: lost.isEmpty ? nil : lost))

        case .clearLost:
            registry.clearLost(); reply(.ok)

        case let .create(dir, agent, argv, name):
            do {
                let s = try registry.create(dir: dir, agent: agent, argv: argv ?? [agent], name: name)
                attachOutputFanout(for: s.name)
                reply(.session(s))
            } catch let e as RegistryError {
                reply(errorResult(e))
            } catch {
                reply(.error(code: "spawnFailed", message: "\(error)"))
            }

        case let .kill(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            registry.kill(name: name); reply(.ok)

        case let .rename(name, newName):
            do { try registry.rename(name: name, newName: newName); reply(.ok) }
            catch let e as RegistryError { reply(errorResult(e)) }
            catch { reply(.error(code: "badRequest", message: "\(error)")) }

        case let .attach(name, sinceSeq):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name, default: []].insert(sink.id)
            if let bf = registry.backfill(name: name, since: sinceSeq ?? 0), !bf.bytes.isEmpty {
                sink.send(.event(.output(name: name, seq: bf.fromSeq,
                                         bytesB64: Data(bf.bytes).base64EncodedString())))
            }
            reply(.ok)

        case let .detach(name):
            guard registry.get(name: name) != nil else { return notFound(name) }
            subscribers[name]?.remove(sink.id); reply(.ok)

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
        }
    }
}
