import XCTest
@testable import CoveyGit

/// Bare "origin" + a clone of it; the clone is the repo under test.
/// Mirrors the private makeClonedRepo() precedent in RepositoryTests.
final class TestClonedRepo {
    let path: String        // the clone
    let origin: String      // the bare remote
    let branch = "dev"

    init() throws {
        origin = "\(NSTemporaryDirectory())covey-origin-\(UInt32.random(in: 0..<UInt32.max)).git"
        path = "\(NSTemporaryDirectory())covey-clone-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try sh("git init -q --bare '\(origin)'")
        try sh("git clone -q '\(origin)' '\(path)'")
        try sh("git -C '\(path)' switch -q -c dev")
        try "one".write(toFile: "\(path)/f.txt", atomically: true, encoding: .utf8)
        try sh("git -C '\(path)' add f.txt && git -C '\(path)' -c user.email=t@t -c user.name=t commit -q -m one")
        try sh("git -C '\(path)' push -q -u origin dev")
    }

    func sh(_ cmd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ShellError(description: "sh failed: \(cmd)") }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: origin)
    }

    /// Advances the bare origin's `dev` by one empty commit (commit-tree on the
    /// bare repo — no second clone). Returns the new OID.
    @discardableResult
    func advanceRemoteBranch() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "tree=$(git -C '\(origin)' rev-parse dev^{tree}); "
            + "new=$(git -C '\(origin)' -c user.email=t@t -c user.name=t commit-tree $tree -p $(git -C '\(origin)' rev-parse dev) -m ahead); "
            + "git -C '\(origin)' update-ref refs/heads/dev $new; echo $new"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ShellError(description: "advance failed") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
