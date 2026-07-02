import Darwin
import Foundation

/// Shared sockaddr_un plumbing for unix-domain socket clients.
enum UnixSocket {
    /// connect(2) `fd` to the unix socket at `path`.
    /// Returns 0 on success, -1 on failure (errno set by the syscall).
    static func connect(_ fd: Int32, to path: String) -> Int32 {
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
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
    }
}
