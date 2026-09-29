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
/// before touching stderr (what `GitOps.run` did) deadlocks as soon as the
/// child fills the stderr pipe buffer and blocks writing to it.
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
                    drained.leave()
                } else if !buffers.append(chunk, stdout: isStdout) {
                    process.terminate()
                }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        func detach() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
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

private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var out = Data()
    private var err = Data()
    private var tooLarge = false

    init(limit: Int) { self.limit = limit }

    /// False once stdout + stderr pass the limit; the caller then kills the child.
    func append(_ chunk: Data, stdout: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stdout { out.append(chunk) } else { err.append(chunk) }
        if out.count + err.count > limit { tooLarge = true }
        return !tooLarge
    }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return tooLarge }
}
