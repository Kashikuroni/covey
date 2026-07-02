import Foundation
import CoveydCore

// Resolve ~/.covey/coveyd.sock
let home = FileManager.default.homeDirectoryForCurrentUser
let dir = home.appendingPathComponent(".covey", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let socketPath = dir.appendingPathComponent("coveyd.sock").path

// Single-instance: if an existing socket accepts a connection, another daemon is alive.
if FileManager.default.fileExists(atPath: socketPath) {
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    _ = socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathSize) {
                strlcpy($0, src, pathSize)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let alive = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } == 0
    }
    close(probe)
    if alive {
        FileHandle.standardError.write(Data("coveyd: already running at \(socketPath)\n".utf8))
        exit(1)
    }
    unlink(socketPath)   // stale socket
}

let registryStore = RegistryStore(path: dir.appendingPathComponent("registry.json").path)
let registry = SessionRegistry(persisted: registryStore.load(),
                               onPersist: { registryStore.save($0) })
let monitor = StatusMonitor(snapshot: { registry.snapshotScreens() })
let ipc = IPCServer(registry: registry, monitor: monitor)
let server = SocketServer(path: socketPath)
server.onAccept = { conn in
    ipc.register(conn)
    conn.onRequest = { req, c in ipc.handle(req, from: c) }
    conn.onBadRequest = { id, c in ipc.handleBadRequest(id: id, from: c) }
    conn.onClose = { c in ipc.unregister(c) }
    conn.start()
}

// Cleanup the socket file on termination. A signal(2) handler must be a context-free
// C function, so use DispatchSource signal sources (their closures may capture).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let onSignal: () -> Void = { unlink(socketPath); exit(0) }
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
termSource.setEventHandler(handler: onSignal)
intSource.setEventHandler(handler: onSignal)
termSource.resume()
intSource.resume()

do {
    try server.start()
    FileHandle.standardError.write(Data("coveyd: listening at \(socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("coveyd: failed to start: \(error)\n".utf8))
    exit(1)
}

monitor.start()

dispatchMain()
