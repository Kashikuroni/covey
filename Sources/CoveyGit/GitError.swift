import Foundation

/// The one error CoveyGit throws. `description` is the user-facing message:
/// the daemon forwards it verbatim in IPC error replies, so it must stay
/// exactly what git (or the refusing check) said.
public struct GitError: Error, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A precondition refused the operation (protected branch, dirty tree…).
        case refused
        /// git ran and exited non-zero.
        case failed(status: Int32)
        /// git did not finish within the timeout and was terminated.
        case timedOut
        /// git produced more output than the caller allowed.
        case outputTooLarge
        /// The process could not be launched at all.
        case launchFailed
        /// A ref the caller named does not resolve to a commit.
        case unknownRef(String)
    }

    public let kind: Kind
    public let description: String

    /// A refusal with a message — the form every precondition check uses.
    public init(_ description: String) {
        self.init(kind: .refused, description: description)
    }

    public init(kind: Kind, description: String) {
        self.kind = kind
        self.description = description
    }
}
