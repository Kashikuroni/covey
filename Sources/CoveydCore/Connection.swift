import Foundation
import CoveyKit

public protocol ClientSink: AnyObject {
    var id: Int { get }
    func send(_ message: ServerMessage)
}

public final class Connection: ClientSink {
    public let id: Int
    public var onRequest: ((Request, Connection) -> Void)?
    public var onBadRequest: ((Int?, Connection) -> Void)?
    public var onClose: ((Connection) -> Void)?
    
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var closed = false
    /// Keeps the connection alive from `start()` until `close()`. Nothing else holds
    /// a strong reference to an accepted connection, and the read source captures
    /// `self` weakly, so without this the object would deallocate immediately.
    private var selfRetain: Connection?
    
    public init(fd: Int32, id: Int) {
        self.fd = fd
        self.id = id
        self.queue = DispatchQueue(label: "covey.conn.\(id)")
    }
    
    public func start() {
        selfRetain = self
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        let fd = self.fd
        src.setCancelHandler { Darwin.close(fd) }
        readSource = src
        src.resume()
    }
    public func send(_ message: ServerMessage) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard let line = try? NDJSON.encodeLine(message) else { return }
            
            line.withUnsafeBytes { raw in
                guard var base = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let n = write(self.fd, base, remaining)
                    if n > 0 {
                        base = base.advanced(by: n)
                        remaining -= n
                    }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
        }
    }
    public func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.readSource?.cancel()
            self.onClose?(self)
            self.selfRetain = nil
        }
    }
    
    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count ) }
        if n > 0 {
            let chunk = Array(buf[0..<n])
            let lines: [[UInt8]]
            do { lines = try framer.feed(chunk) }
            catch { onBadRequest?(nil, self); close(); return }
            for line in lines { dispatchLine(line) }
        } else {
            close()
        }
    }
    
    private func dispatchLine(_ line: [UInt8]) {
        let data = Data(line)
        struct Header: Decodable { let id: Int }
        if let req = try? NDJSON.decoder.decode(Request.self, from: data) {
            onRequest?(req, self)
        } else {
            let id = (try? NDJSON.decoder.decode(Header.self, from: data))?.id
            onBadRequest?(id, self)
        }
    }
}
