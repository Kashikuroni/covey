import Foundation

public enum SocketError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
}

public final class SocketServer {
    public var onAccept: ((Connection) -> Void)?
    
    private let path: String
    private let queue = DispatchQueue(label: "covey.listener")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var nextConnID = 0
    
    public init(path: String) { self.path = path }
    
    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.socketFailed(errno)
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path, { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathSize, { strlcpy($0, src, pathSize)})
            })
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr, { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                bind(fd, $0, len)
            })
        })
        guard bindOK == 0 else {
            Darwin.close(fd); throw SocketError.bindFailed(errno)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            Darwin.close(fd); throw SocketError.listenFailed(errno)
        }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD); self.listenFD = -1
        }
        acceptSource = src
        src.resume()
    }
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptSource?.cancel()
            unlink(self.path)
        }
    }
    
    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        // Broadcasts race client teardown: a write after the peer closed must
        // return EPIPE, not raise SIGPIPE (default action kills the process).
        var on: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        nextConnID += 1
        let conn = Connection(fd: clientFD, id: nextConnID)
        onAccept?(conn)
    }
}
