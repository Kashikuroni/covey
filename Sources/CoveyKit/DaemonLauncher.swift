import Darwin
import Foundation

public enum DaemonLauncher {
    /// Returns once a live daemon accepts connections on `socketPath`.
    /// If nothing accepts, spawns `binaryPath` and polls every 50 ms up to
    /// `timeout`, then throws `connectFailed(ETIMEDOUT)`. A stale socket file
    /// is NOT removed here — the daemon does that itself on startup.
    public static func ensureDaemon(socketPath: String, binaryPath: String,
                                    timeout: TimeInterval = 5) throws {
        if probe(socketPath) { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        try proc.run()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe(socketPath) { return }
            usleep(50_000)
        }
        throw IPCClientError.connectFailed(ETIMEDOUT)
    }

    /// True if connect(2) on the unix socket succeeds (a live daemon accepts).
    private static func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return UnixSocket.connect(fd, to: path) == 0
    }
}
