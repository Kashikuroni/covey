import Darwin
import Dispatch

public enum PTYError: Error {
    case spawnFailed(Int32)
}

/// The seam between SessionRegistry and however a session's process is
/// actually run. PTYSessionRuntime is the only implementation today (a PTY
/// via forkpty); this exists so SessionRegistry's PTY-lifecycle logic
/// doesn't need to change shape when a non-PTY runtime is introduced later.
public protocol SessionRuntime: AnyObject {
    func setOutputHandler(_ handler: (([UInt8], Int) -> Void)?)
    func setExitHandler(_ handler: ((Int32) -> Void)?)
    func spawn(argv: [String], env: [String: String]?, cwd: String?,
               cols: UInt16, rows: UInt16) throws
    func write(_ bytes: [UInt8])
    func resize(cols: UInt16, rows: UInt16)
    func kick()
    func kill()
    func backfill(since seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool)
    func scrollbackTail(_ maxBytes: Int) -> [UInt8]
}

/// Owns one child process running in its own PTY: spawn via forkpty, read output
/// through a DispatchSource, write input, resize, kill. Byte-transparent.
public final class PTYSessionRuntime: SessionRuntime {
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
    /// Input the kernel would not take yet (raw-mode child stopped reading its
    /// tty). Drained by a write source; capped so a wedged child cannot grow
    /// memory without bound — overflow is dropped like a full kernel queue.
    private var pendingInput = [UInt8]()
    private var writeSource: DispatchSourceWrite?
    private let pendingInputLimit = 262_144
    
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
        precondition(pid == -1, "PTYSessionRuntime already spawned")
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
        // Non-blocking: a raw-mode child that stops reading fills the kernel
        // input queue, and a blocking write would wedge the pty queue forever
        // (freezing kill/backfill for the whole daemon).
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        startReadLoop()
    }
    
    public func write(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            if self.pendingInput.count + bytes.count <= self.pendingInputLimit {
                self.pendingInput += bytes
            }
            self.drainPendingInput()
        }
    }

    /// Writes as much of `pendingInput` as the kernel takes; on EAGAIN parks
    /// the rest and arms a write source to continue when the fd drains.
    private func drainPendingInput() {
        guard masterFD >= 0 else {
            pendingInput.removeAll()
            return
        }
        while !pendingInput.isEmpty {
            let n = pendingInput.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(masterFD, base, raw.count)
            }
            if n > 0 {
                pendingInput.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue // interrupted by a signal - retry
            } else if n < 0 && errno == EAGAIN {
                armWriteSource()
                return
            } else {
                pendingInput.removeAll() // EOF or fatal error (e.g. EPIPE: child gone)
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        src.setEventHandler { [weak self] in self?.drainPendingInput() }
        writeSource = src
        src.resume()
    }
    
    public func resize(cols: UInt16, rows: UInt16) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else {return}
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &ws)
        }
    }
    
    /// Nudges the child into a full repaint. TIOCSWINSZ with an unchanged
    /// size does not signal, so attach sends an explicit SIGWINCH to the
    /// process group after replaying backfill: a freshly mounted GUI
    /// emulator needs one complete frame, not the torn tail of the ring.
    public func kick() {
        queue.async { [weak self] in
            guard let self, self.pid > 0, !self.reaped else { return }
            _ = Darwin.kill(-self.pid, SIGWINCH)
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
        // ScrollbackBuffer synchronizes internally — never hop through the pty
        // queue here: a stalled queue would cascade into the IPC thread.
        buffer.since(seq)
    }

    /// The last `maxBytes` of scrollback (see ScrollbackBuffer.tail). Used to
    /// scan a dying claude's output for its `--resume` hint.
    public func scrollbackTail(_ maxBytes: Int) -> [UInt8] {
        buffer.tail(maxBytes)
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
        } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
            return  // spurious wakeup on the non-blocking fd
        } else {
            reap()  // EOF (n == 0) or EIO after the child exits (n < 0)
        }
    }
    
    private func reap() {
        guard !reaped else { return }
        reaped = true
        // Cancel the write source before the read source's cancel handler
        // closes the fd — a live source on a closed fd is undefined.
        writeSource?.cancel()
        writeSource = nil
        pendingInput.removeAll()
        readSource?.cancel()
        var status: Int32 = 0
        // Safe to block: on macOS the master EOFs only once the session leader
        // has exited (tty revoke), so the child is already a zombie here. Pinned
        // by PTYSessionRuntimeTests.testMasterEOFImpliesChildExited.
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
