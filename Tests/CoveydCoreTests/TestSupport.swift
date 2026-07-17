import XCTest
@testable import CoveydCore

extension XCTestCase {
    func bytes(_ s: String) -> [UInt8] {Array(s.utf8) }

    /// Expectation that fulfills once the process's accumulated output
    /// contains `needle`.
    func expectOutput(_ p: PTYSessionRuntime, contains needle: String) -> XCTestExpectation {
        let exp = expectation(description: "output contains \(needle)")
        exp.assertForOverFulfill = false
        var collected = [UInt8]()
        p.setOutputHandler { chunk, _ in
            collected += chunk
            if String(decoding: collected, as: UTF8.self).contains(needle) {
                exp.fulfill()
            }
        }
        return exp
    }

    /// Polls `cond` every 20 ms until true, failing the test after 5 s.
    func waitUntil(_ cond: @escaping () -> Bool, _ desc: String) {
        let exp = expectation(description: desc)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { if cond() { timer.cancel(); exp.fulfill() } }
        timer.resume()
        wait(for: [exp], timeout: 5)
    }
}

/// Minimal blocking client over a unix-domain socket, for end-to-end tests.
final class IPCTestClient {
    private let fd: Int32
    
    init(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathSize) {
                    strlcpy($0, src, pathSize)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr, { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1){
                connect(fd, $0, len)
            }
        })
    }
    
    func sendLine(_ s: String) {
        var data = Array(s.utf8); data.append(0x0A)
        data.withUnsafeBytes {
            _ = write(fd, $0.baseAddress, $0.count)
        }
    }
    
    ///Reads until a full line (`\n`) is available; returns it without the newline.
    func readLine() -> String {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            line.append(byte)
        }
        return String(decoding: line, as: UTF8.self)
    }
    
    func close() { Darwin.close(fd) }
}


