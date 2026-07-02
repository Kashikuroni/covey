import Darwin
import Dispatch

public enum PTYError: Error {
    case spawnFailed(Int32)
}

/// Owns one child process running in its own PTY: spawn via forkpty, read output
/// through a DispatchSource, write input, resize, kill. Byte-transparent.
public final class PTYProcess {
    /// Output handler, invoked on the internal queue with each chunk and the
    /// seq of its first byte. Assign it via `setOutputHandler`.
    private var onOutput: (([UInt8], Int) -> Void)?
    /// Exit handler, invoked once on the internal queue with the exit code.
    /// Assign it via `setExitHandler`.
    private var onExit: ((Int32) -> Void)?
    
    private let buffer: ScrollbackBuffer
    private let queue = DispatchQueue(label: "covey.pty")
    private var readSource: DispatchSourceRead?
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var reaped = false
    
    public init(scrollbackLimit: Int = 1_000_000) {
        self.buffer = ScrollbackBuffer(limit: scrollbackLimit)
    }
    
    /// Sets the output handler on the internal queue, so it is never written
    /// concurrently with the read loop that invokes it.
    public func setOutputHandler(_ handler: (([UInt8], Int) -> Void)?) {
        queue.async { [weak self] in self?.onOutput = handler }
    }
    
    /// Sets the exit handler on the internal queue (same reasoning).
    public func setExitHandler(_ handler: ((Int32) -> Void)?) {
        queue.async { [weak self] in self?.onExit = handler }
    }
    
    public func spawn(
        argv:  [String], env: [String: String]? = nil, cwd: String? = nil,
        cols: UInt16, rows: UInt16
    ) throws {
        precondition(pid == -1, "PTYProcess already spawned")
        precondition(!argv.isEmpty, "argv must not be empty")
        
        // Prepare all C strings in the PARENT. Between fork and exec the child may
        // only call async-signal-safe functions, so no malloc (strdup) there.
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map {strdup($0)}
        cargs.append(nil)
        let cwdC = cwd.map { strdup($0)}
        defer {
            for case let arg? in cargs { free(arg)}
            if let cwdC { free(cwdC)}
        }
        
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0
        let childPid = forkpty(&master, nil, nil, &ws)
        
        if childPid < 0 {
            throw PTYError.spawnFailed(errno)
        }
        
        if childPid == 0 {
            // CHILD: async-signal-safe calls only. `env` is inherited in slice 1.
            // Reset signal state: ignored dispositions and the blocked mask
            // survive fork+exec, so a parent that ignores SIGTERM (coveyd does,
            // for its own shutdown handling) would breed unkillable children.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            signal(SIGTERM, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGHUP, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            if let cwdC { _ = chdir(cwdC)}
            execvp(cargs[0]!, &cargs) // returns only if exec failed
            _exit(127)
        }
        
        // PARENT
        pid = childPid
        masterFD = master
        startReadLoop()
    }
    
    public func write(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            bytes.withUnsafeBytes { raw in
                guard var base = raw.baseAddress else {return}
                var remaining = raw.count
                while remaining > 0 {
                    let n = Darwin.write(self.masterFD, base, remaining)
                    if n > 0 {
                        base = base.advanced(by: n)
                        remaining -= n
                    } else if n < 0 && errno == EINTR {
                        continue // interrupted by a signal - retry
                    } else {
                        break // EOF or fatal error (e.g. EPIPE: child gone)
                    }
                }
            }
        }
    }
    
    public func resize(cols: UInt16, rows: UInt16) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else {return}
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &ws)
        }
    }
    
    public func kill() {
        queue.async { [weak self] in
            guard let self, self.pid > 0, !self.reaped else { return }
            // forkpty made the child a session leader (pgid == pid), so signal the
            // whole process group to also reach any grandchildren. Interactive
            // shells IGNORE SIGTERM but honor SIGHUP (the "terminal closed"
            // signal), so send SIGHUP first, then escalate to SIGKILL for anything
            // that survives (the read loop reaps once the child finally dies).
            let pid = self.pid
            _ = Darwin.kill(-pid, SIGHUP)
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.pid == pid, !self.reaped else { return }
                _ = Darwin.kill(-pid, SIGKILL)
            }
        }
    }
    
    public func backfill(since seq: Int) -> (
        bytes: [UInt8], fromSeq: Int, gapped: Bool
    ) {
        queue.sync { buffer.since(seq)}
    }
    
    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        src.setEventHandler{ [weak self] in self?.handleReadable()}
        src.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD)
            self.masterFD = -1
        }
        readSource = src
        src.resume()
    }
    
    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else {return -1}
            return read(masterFD, base, raw.count)
        }
        if n > 0 {
            let chunk = Array(buf[0..<n])
            let range = buffer.append(chunk)
            onOutput?(chunk, range.from)
        } else {
            reap()  // EOF (n == 0) or EIO after the child exits (n < 0)
        }
    }
    
    private func reap() {
        guard !reaped else { return }
        reaped = true
        readSource?.cancel()
        var status: Int32 = 0
        // Safe to block: on macOS the master EOFs only once the session leader
        // has exited (tty revoke), so the child is already a zombie here. Pinned
        // by PTYProcessTests.testMasterEOFImpliesChildExited.
        _ = waitpid(pid, &status, 0)
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }
        onExit?(code)
    }
}
