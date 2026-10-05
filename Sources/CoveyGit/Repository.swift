import Foundation

/// One git working tree (the main checkout or a linked worktree), addressed
/// by a directory inside it. A value: cheap to create per call.
public struct Repository: Hashable, Sendable {
    public let path: String

    public init(at path: String) {
        self.path = path
    }

    /// `git -C path args…`, trimmed stdout, throws on non-zero exit.
    @discardableResult
    func git(_ args: [String], readOnly: Bool = false) throws -> String {
        try GitRunner.run(in: path, args, readOnly: readOnly)
    }

    static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
