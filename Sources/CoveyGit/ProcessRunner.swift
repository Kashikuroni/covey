import Foundation

/// Raw result of one child process. Exit status is data here, not an error.
struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum ProcessFailure: Error, Equatable {
    case launch(String)
    case timedOut
    case outputTooLarge
}

/// Runs a child with both pipes drained concurrently. Reading stdout to EOF
/// before touching stderr (what the old daemon-side runner did) deadlocks as
/// soon as the child fills the stderr pipe buffer and blocks writing to it.
enum ProcessRunner {
    static func run(executable: String, arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval, outputLimit: Int) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffers = OutputBuffers(limit: outputLimit)
        let drained = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if buffers.finish(stdout: isStdout) { drained.leave() }
                } else if buffers.append(chunk, stdout: isStdout) {
                    process.terminate()
                }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Every `enter()` above is matched by exactly one `leave()`: the EOF
        // handler's, or this one for a pipe that never reached EOF.
        func detach() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            for _ in 0..<buffers.abandonOpenPipes() { drained.leave() }
        }

        do {
            try process.run()
        } catch {
            detach()
            throw ProcessFailure.launch("\(error)")
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            detach()
            throw ProcessFailure.timedOut
        }
        // EOF follows the exit closely; bounded so a grandchild that inherited
        // the pipe cannot hang the caller.
        _ = drained.wait(timeout: .now() + 2)
        detach()
        if buffers.overflowed { throw ProcessFailure.outputTooLarge }
        return ProcessResult(stdout: buffers.stdout, stderr: buffers.stderr,
                             status: process.terminationStatus)
    }
}

/// The shared, lock-guarded state of one run: the captured bytes, the output cap,
/// and which pipes still owe the drain group a `leave()`.
final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var out = Data()
    private var err = Data()
    private var tooLarge = false
    // Each pipe is open until it reaches EOF or is abandoned by `detach`.
    private var stdoutOpen = true
    private var stderrOpen = true

    init(limit: Int) { self.limit = limit }

    /// True exactly once: for the chunk that first pushes stdout + stderr past the
    /// limit. The caller terminates the child then, and never again.
    func append(_ chunk: Data, stdout: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stdout { out.append(chunk) } else { err.append(chunk) }
        guard !tooLarge, out.count + err.count > limit else { return false }
        tooLarge = true
        return true
    }

    /// A pipe reached EOF. True when the caller now owns that pipe's group
    /// `leave()`; false when detach already settled it.
    func finish(stdout: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stdout {
            guard stdoutOpen else { return false }
            stdoutOpen = false
        } else {
            guard stderrOpen else { return false }
            stderrOpen = false
        }
        return true
    }

    /// Settles every pipe that has not reached EOF and returns how many group
    /// `leave()`s the caller owes for them. A later `finish` then returns false.
    func abandonOpenPipes() -> Int {
        lock.lock(); defer { lock.unlock() }
        let owed = (stdoutOpen ? 1 : 0) + (stderrOpen ? 1 : 0)
        stdoutOpen = false
        stderrOpen = false
        return owed
    }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return tooLarge }
}
