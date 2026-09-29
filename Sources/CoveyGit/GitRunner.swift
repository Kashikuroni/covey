import Foundation

public struct GitOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
}

/// The only place covey launches `git`.
public enum GitRunner {
    /// A safety net, not a budget: the slowest legitimate daemon call is a
    /// `worktree add` on a large checkout. Interactive reads pass their own.
    public static let defaultTimeout: TimeInterval = 300
    public static let defaultOutputLimit = 256 << 20

    /// `git -C dir args…` with raw (untrimmed) output. The exit status is part
    /// of the answer; only launch failure, timeout and the output cap throw.
    public static func execute(in dir: String, _ args: [String], readOnly: Bool,
                               timeout: TimeInterval = defaultTimeout,
                               outputLimit: Int = defaultOutputLimit) throws -> GitOutput {
        let command = "git \(args.joined(separator: " "))"
        do {
            let result = try ProcessRunner.run(
                executable: "/usr/bin/env", arguments: ["git", "-C", dir] + args,
                environment: environment(readOnly: readOnly),
                timeout: timeout, outputLimit: outputLimit)
            return GitOutput(stdout: String(decoding: result.stdout, as: UTF8.self),
                             stderr: String(decoding: result.stderr, as: UTF8.self),
                             status: result.status)
        } catch ProcessFailure.timedOut {
            throw GitError(kind: .timedOut,
                           description: "\(command) timed out after \(Int(timeout.rounded(.up)))s")
        } catch ProcessFailure.outputTooLarge {
            throw GitError(kind: .outputTooLarge, description: "\(command) produced too much output")
        } catch ProcessFailure.launch(let reason) {
            throw GitError(kind: .launchFailed, description: "could not run git: \(reason)")
        }
    }

    /// Trimmed stdout; a non-zero exit throws `.failed` carrying git's stderr
    /// (or the command line when git said nothing).
    @discardableResult
    public static func run(in dir: String, _ args: [String], readOnly: Bool = false,
                           timeout: TimeInterval = defaultTimeout) throws -> String {
        let out = try execute(in: dir, args, readOnly: readOnly, timeout: timeout)
        guard out.status == 0 else {
            let message = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(kind: .failed(status: out.status),
                           description: message.isEmpty
                               ? "git \(args.joined(separator: " ")) failed" : message)
        }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `LC_ALL=C` always, so parsed English words are stable; reads add
    /// `GIT_OPTIONAL_LOCKS=0` so they never stall on (or take) the index lock.
    public static func environment(readOnly: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" }
        return env
    }
}
